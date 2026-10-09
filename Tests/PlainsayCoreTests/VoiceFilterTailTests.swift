import FluidAudio
import Foundation
import Testing
@testable import PlainsayCore

/// The voice filter's keep/remove decision, on hand-built diarizer segments.
///
/// Shaped after the 37.03 s dictation of 2026-10-08 that came back cut off
/// mid-sentence: the diarizer's 10 s windows put the last 7 s in a padded
/// window of their own, whose embedding is the weakest of the recording.
@Suite("Voice filter keeps the user's own audio")
struct VoiceFilterTailTests {
    private static let rate = Int(whisperSampleRate)
    /// 592421 samples, the length of the truncated recording.
    private static let samples: [Float] = (0..<592_421).map { Float($0) }

    private static let enrolled: [Float] = [1, 0, 0, 0]
    /// Cosine distance 0.7 from the enrollment — over the 0.6 threshold, and
    /// well inside the 0.84 the diarizer itself uses to call it the same voice.
    private static let weakSameVoice: [Float] = [0.3, (1 - 0.09).squareRoot(), 0, 0]
    private static let otherVoice: [Float] = [0, 0, 1, 0]

    private static func segment(
        _ speaker: String, _ embedding: [Float], _ start: Float, _ end: Float
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speaker, embedding: embedding,
            startTimeSeconds: start, endTimeSeconds: end, qualityScore: 1
        )
    }

    private static func filter(_ segments: [TimedSpeakerSegment]) -> [Float] {
        VoiceFilterEngine.removingOtherSpeakers(
            from: samples, segments: segments, matching: enrolled, threshold: 0.6
        )
    }

    @Test("The last window survives when its embedding is weak but its speaker is the user")
    func weakTailWindowIsKept() {
        let kept = Self.filter([
            Self.segment("1", Self.enrolled, 0, 10),
            Self.segment("1", Self.enrolled, 10, 20),
            Self.segment("1", Self.enrolled, 20, 30),
            Self.segment("1", Self.weakSameVoice, 30, 37.02),
        ])
        #expect(kept.count == Self.samples.count)
        #expect(kept.last == Self.samples.last)
    }

    @Test("Speech the diarizer left unattributed is not thrown away")
    func unattributedTailIsKept() {
        // Nothing after 35 s: a closing phrase under the diarizer's 1 s
        // minimum, or a window whose embedding failed validation.
        let kept = Self.filter([
            Self.segment("1", Self.enrolled, 0, 10),
            Self.segment("1", Self.enrolled, 10, 20),
            Self.segment("1", Self.enrolled, 20, 35),
        ])
        #expect(kept.count == Self.samples.count)
    }

    @Test("A second voice is still removed")
    func otherSpeakerIsRemoved() {
        let kept = Self.filter([
            Self.segment("1", Self.enrolled, 0, 20),
            Self.segment("2", Self.otherVoice, 20, 25),
            Self.segment("1", Self.enrolled, 25, 37.02),
        ])
        #expect(kept.count == Self.samples.count - 5 * Self.rate)
        #expect(!kept.contains(Float(22 * Self.rate)))
        #expect(kept.last == Self.samples.last)
    }

    @Test("Where the user talks over a second voice, the overlap stays")
    func overlapWithUserIsKept() {
        let kept = Self.filter([
            Self.segment("1", Self.enrolled, 0, 22),
            Self.segment("2", Self.otherVoice, 20, 25),
            Self.segment("1", Self.enrolled, 25, 37.02),
        ])
        #expect(kept.count == Self.samples.count - 3 * Self.rate)
        #expect(kept.contains(Float(21 * Self.rate)))
        #expect(!kept.contains(Float(23 * Self.rate)))
    }

    @Test("No confident match leaves the recording untouched")
    func noMatchFailsOpen() {
        let kept = Self.filter([
            Self.segment("2", Self.otherVoice, 0, 37.02),
        ])
        #expect(kept == Self.samples)
    }
}

/// Shaped after the 43.54 s dictation of 2026-10-08 17:43 that logged
/// "voice filter kept 42.21s of 43.54s" and came back ending mid-sentence.
/// The diarizer's last window holds 3.54 s of audio padded to 10 s; a closing
/// phrase of 1.33 s there is long enough (the diarizer's minimum is 1 s) to be
/// minted as a brand-new speaker, which the filter then removed as "someone
/// else".
@Suite("Voice filter keeps the user's closing words")
struct VoiceFilterClosingSpanTests {
    private static let rate = Int(whisperSampleRate)
    /// 43.54 s, the length of the truncated recording.
    private static let samples: [Float] = (0..<696_640).map { Float($0) }

    private static let enrolled: [Float] = [1, 0, 0, 0]
    private static let otherVoice: [Float] = [0, 0, 1, 0]
    /// What the last, mostly-padding window makes of the user's own voice:
    /// over the 0.6 threshold from the enrollment.
    private static let paddedTail: [Float] = [0.2, 0, (1 - 0.04).squareRoot(), 0]

    private static func segment(
        _ speaker: String, _ embedding: [Float], _ start: Float, _ end: Float
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speaker, embedding: embedding,
            startTimeSeconds: start, endTimeSeconds: end, qualityScore: 1
        )
    }

    private static func filter(_ segments: [TimedSpeakerSegment]) -> VoiceFilterOutcome {
        VoiceFilterEngine.filtering(
            samples, segments: segments, matching: enrolled, threshold: 0.6
        )
    }

    @Test("A short closing phrase minted as a new speaker is kept")
    func shortNewSpeakerAtTheEndIsKept() {
        let outcome = Self.filter([
            Self.segment("1", Self.enrolled, 0, 10),
            Self.segment("1", Self.enrolled, 10, 20),
            Self.segment("1", Self.enrolled, 20, 30),
            Self.segment("1", Self.enrolled, 30, 40),
            Self.segment("1", Self.enrolled, 40, 42.21),
            Self.segment("3", Self.paddedTail, 42.21, 43.54),
        ])
        #expect(outcome.samples.count == Self.samples.count)
        #expect(outcome.samples.last == Self.samples.last)
        #expect(outcome.removed.isEmpty)
    }

    @Test("A longer closing stretch from a speaker first heard in the padded last window is kept")
    func speakerBornInLastWindowIsKept() {
        let outcome = Self.filter([
            // Segments never straddle a window: the diarizer emits them per 10 s window.
            Self.segment("1", Self.enrolled, 0, 39.5),
            Self.segment("3", Self.paddedTail, 40, 43.54),
        ])
        #expect(outcome.samples.count == Self.samples.count)
        #expect(outcome.removed.isEmpty)
    }

    @Test("A brief interjection is too little evidence of a second person")
    func briefInterjectionIsKept() {
        let outcome = Self.filter([
            Self.segment("1", Self.enrolled, 0, 15),
            Self.segment("2", Self.otherVoice, 15, 17),
            Self.segment("1", Self.enrolled, 17, 43.54),
        ])
        #expect(outcome.samples.count == Self.samples.count)
    }

    @Test("A second voice heard earlier is still removed when it also speaks last")
    func establishedSecondVoiceAtTheEndIsRemoved() {
        let outcome = Self.filter([
            Self.segment("1", Self.enrolled, 0, 20),
            Self.segment("2", Self.otherVoice, 20, 25),
            Self.segment("1", Self.enrolled, 25, 41),
            Self.segment("2", Self.otherVoice, 41, 43.54),
        ])
        #expect(outcome.removed == [20..<25, 41..<43.54])
        #expect(outcome.samples.count == Self.samples.count - 5 * Self.rate - (696_640 - 41 * Self.rate))
    }

    @Test("Removed stretches are reported as time ranges for the log")
    func removedRangesAreReported() {
        let outcome = Self.filter([
            Self.segment("1", Self.enrolled, 0, 20),
            Self.segment("2", Self.otherVoice, 20, 25),
            Self.segment("1", Self.enrolled, 25, 43.54),
        ])
        #expect(outcome.removed == [20..<25])
        #expect(VoiceFilterOutcome.describe(outcome.removed) == "20.00-25.00s")
    }
}
