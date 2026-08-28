import Foundation
import Testing
@testable import PlainsayCore

@Suite("Live preview pacing")
@MainActor
struct LivePreviewPacingTests {
    @Test("A cheap pass still waits the minimum, rather than spinning the engine")
    func fastPassIsFloored() {
        let next = DictationCoordinator.nextPreviewInterval(afterPassLasting: .milliseconds(20))
        #expect(next == DictationCoordinator.previewInterval)
    }

    @Test("An expensive pass waits as long as it took, so passes never overlap")
    func slowPassPacesItself() {
        // Each pass re-transcribes the whole recording, so cost grows with
        // length. Waiting as long as the last pass took holds the preview at
        // roughly half duty however long the dictation runs.
        let next = DictationCoordinator.nextPreviewInterval(afterPassLasting: .milliseconds(900))
        #expect(next == .milliseconds(900))
    }

    @Test("Backoff is capped, so a long dictation still updates")
    func backoffIsCapped() {
        let next = DictationCoordinator.nextPreviewInterval(afterPassLasting: .seconds(30))
        #expect(next == DictationCoordinator.previewMaximumInterval)
    }

    @Test("The first preview comes sooner than the old fixed cadence")
    func firstPreviewIsQuick() {
        // The first pass is when someone is watching most closely, and it used
        // to be the slowest thing that happened: a flat 1.5s of nothing.
        #expect(DictationCoordinator.previewInterval < .milliseconds(1500))
    }
}

@Suite("Recording tail")
struct RecordingTailTests {
    private func samples(count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { _ in amplitude }
    }

    @Test("A recording that ends loud is flagged as cut mid-speech")
    func loudTailIsFlagged() {
        // 2 seconds, still at speaking volume when it stops.
        #expect(AudioRecorder.endedMidSpeech(samples(count: 32000, amplitude: 0.3)))
    }

    @Test("A recording that trails into silence is not flagged")
    func quietTailIsFine() {
        // Someone who finished their sentence leaves a pause before letting go.
        var audio = samples(count: 24000, amplitude: 0.3)
        audio += samples(count: 8000, amplitude: 0.0005)
        #expect(!AudioRecorder.endedMidSpeech(audio))
    }

    @Test("A clip shorter than the inspection window is never flagged")
    func tooShortToJudge() {
        #expect(!AudioRecorder.endedMidSpeech(samples(count: 100, amplitude: 0.9)))
    }

    @Test("Room tone alone does not count as speech")
    func roomToneIsNotSpeech() {
        #expect(!AudioRecorder.endedMidSpeech(samples(count: 32000, amplitude: 0.005)))
    }
}
