import Foundation
import Testing
@testable import PlainsayCore

/// Keeping the microphone open past the key, but only when it earns it.
@Suite("Tail grace")
@MainActor
struct TailGraceTests {
    @Test("Bounded snapshots preserve short-clip and tail-window decisions")
    func boundedTailDecisions() {
        let window = Int(AudioRecorder.tailWindow * whisperSampleRate)
        for count in [0, window - 1, window, window + 1, window * 4] {
            for speechAtEnd in [false, true] {
                let sink = AudioSampleSink(seconds: 2)
                var samples = [Float](repeating: 0, count: count)
                if count > 0 {
                    // A loud first sample is outside the window on long clips.
                    samples[0] = 0.3
                    samples[count - 1] = speechAtEnd ? 0.3 : 0
                    samples.withUnsafeBufferPointer { sink.append($0.baseAddress!, count: $0.count) }
                }
                let expected = count > window && speechAtEnd
                #expect(AudioRecorder.endedMidSpeech(samples) == expected)
                #expect(AudioRecorder.endedMidSpeech(sink.drain(last: window + 1)) == expected)
            }
        }
    }

    @Test("Custom recorders retain the existing tail check through the protocol")
    func defaultTailCheck() throws {
        let recorder = FakeRecorder()
        let recording: any AudioRecording = recorder
        try recording.start()
        #expect(!recording.isEndingMidSpeech)
        recorder.endsMidWord = true
        #expect(recording.isEndingMidSpeech)
        recorder.duration = AudioRecorder.tailWindow
        #expect(!recording.isEndingMidSpeech)
    }

    private func flat(_ count: Int, _ amplitude: Float) -> [Float] {
        (0..<count).map { _ in amplitude }
    }

    @Test("Speech still going at the key is what opens the grace period")
    func loudAtReleaseOpensIt() {
        // The condition the coordinator checks before waiting at all.
        #expect(AudioRecorder.endedMidSpeech(flat(32000, 0.3)))
    }

    @Test("A sentence finished before the key costs nothing")
    func silenceAtReleaseSkipsIt() {
        // The common case, and the one that must stay instant: waiting a fixed
        // grace on every dictation would charge everybody latency, every time,
        // for something that happens occasionally.
        var audio = flat(24000, 0.3)
        audio += flat(8000, 0.0005)
        #expect(!AudioRecorder.endedMidSpeech(audio))
    }

    @Test("The grace period is short enough not to catch the next thing you say")
    func graceIsBounded() {
        // Long enough for a clipped syllable, short enough that turning to
        // speak to someone else does not end up in the dictation.
        #expect(DictationCoordinator.maximumTailGrace <= .milliseconds(800))
        #expect(DictationCoordinator.maximumTailGrace >= .milliseconds(300))
    }

    @Test("It checks often enough to stop promptly once speech ends")
    func pollsFinely() {
        // The tail ends when the speaker does, not when the clock runs out —
        // otherwise the grace period pastes its own silence onto every use.
        #expect(DictationCoordinator.tailPollInterval <= .milliseconds(100))
    }
}
