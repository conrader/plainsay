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
