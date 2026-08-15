import AppKit
import Foundation
import Testing
@testable import PlainsayCore

// MARK: - Fakes

@MainActor
final class FakeRecorder: AudioRecording {
    var isRecording = false
    var normalizedLevel: Float = 0.5
    var elapsed: TimeInterval = 0
    var startError: Error?
    /// Seconds of audio `stop()` will claim to have captured.
    var duration: TimeInterval = 2.0
    private(set) var cancelCount = 0

    func start() throws {
        if let startError { throw startError }
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        return [Float](repeating: 0.1, count: Int(duration * whisperSampleRate))
    }

    func cancel() {
        isRecording = false
        cancelCount += 1
    }
}

final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    var transcript = "um so the thing is uh it works"
    var error: Error?
    private(set) var receivedPrompt: String?
    private(set) var receivedSampleCount = 0

    func prepare() async throws {}

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        receivedSampleCount = samples.count
        receivedPrompt = prompt
        if let error { throw error }
        return normalizeTranscript(transcript)
    }
}

final class FakeCleaner: TextCleaning, @unchecked Sendable {
    var output = "The thing is, it works."
    var error: Error?
    private(set) var received: String?

    func clean(_ transcript: String, dictionary: TermDictionary) async throws -> String {
        received = transcript
        if let error { throw error }
        return output
    }
}

@MainActor
final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []

    func insert(_ text: String, keepOnClipboard: Bool) async {
        inserted.append(text)
    }
}

// MARK: - Harness

@MainActor
private struct Harness {
    let settings: PlainsaySettings
    let recorder = FakeRecorder()
    let engine = FakeEngine()
    let cleaner = FakeCleaner()
    let inserter = FakeInserter()
    let coordinator: DictationCoordinator
    let history: TranscriptHistory

    init(terms: [String] = []) {
        // An isolated defaults suite so tests never disturb real preferences.
        let suite = UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: suite)
        settings.dictionary = TermDictionary(terms: terms)
        settings.playFeedbackSounds = false
        self.settings = settings

        // Temp directory per harness so tests never touch the real history.
        let history = TranscriptHistory(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("plainsay-pipeline-\(UUID().uuidString)")
        )
        self.history = history

        let engine = self.engine
        let cleaner = self.cleaner
        coordinator = DictationCoordinator(
            settings: settings,
            history: history,
            recorder: recorder,
            inserter: inserter,
            makeEngine: { _, _, _ in engine },
            makeCleaner: { _ in cleaner }
        )
    }

    /// Loads the fake engine without starting the real event tap.
    func ready() async {
        await coordinator.reloadModel()
    }

    func dictate(holdFor seconds: TimeInterval = 1.0) {
        coordinator.handleHotkeyEdge(.down(at: 0))
        coordinator.handleHotkeyEdge(.up(at: seconds))
    }

    /// The pipeline runs in a detached task; wait for it to settle.
    func settle(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !coordinator.phase.isBusy && !inserter.inserted.isEmpty { return }
            if coordinator.phase == .idle && recorder.isRecording == false && !coordinator.phase.isBusy {
                // Give the task one more turn before declaring it finished.
                try await Task.sleep(for: .milliseconds(10))
                if !coordinator.phase.isBusy { return }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Tests

@Suite("Dictation pipeline")
@MainActor
struct PipelineTests {
    @Test("A dictation is transcribed, cleaned, and inserted")
    func happyPath() async throws {
        let harness = Harness()
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        #expect(harness.cleaner.received == "um so the thing is uh it works")
        #expect(harness.inserter.inserted == ["The thing is, it works."])
        #expect(harness.coordinator.phase == .idle)
    }

    @Test("Cleanup failure inserts the raw transcript instead of losing it")
    func cleanupFailureFallsBackToRaw() async throws {
        let harness = Harness()
        harness.cleaner.error = CleanupError.timedOut
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        #expect(harness.inserter.inserted == ["um so the thing is uh it works"])
        // The HUD says so, rather than failing silently.
        #expect(harness.coordinator.phase == .insertedRaw)
    }

    @Test("A stray tap shorter than the minimum inserts nothing")
    func shortRecordingIsDiscarded() async throws {
        let harness = Harness()
        harness.recorder.duration = 0.1
        await harness.ready()

        harness.dictate(holdFor: 0.5)
        try await Task.sleep(for: .milliseconds(100))

        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.coordinator.phase == .idle)
    }

    @Test("Silence produces no paste at all")
    func emptyTranscriptInsertsNothing() async throws {
        let harness = Harness()
        harness.engine.transcript = "[BLANK_AUDIO]"
        await harness.ready()

        harness.dictate()
        try await Task.sleep(for: .milliseconds(200))

        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.coordinator.phase == .idle)
    }

    @Test("A transcription failure surfaces on the HUD and inserts nothing")
    func transcriptionFailureShowsError() async throws {
        let harness = Harness()
        harness.engine.error = TranscriptionError.failed("model exploded")
        await harness.ready()

        harness.dictate()
        try await Task.sleep(for: .milliseconds(200))

        #expect(harness.inserter.inserted.isEmpty)
        if case .error = harness.coordinator.phase {} else {
            Issue.record("expected an error phase, got \(harness.coordinator.phase)")
        }
    }

    @Test("The vocabulary reaches the speech model as a decoder prompt")
    func vocabularyReachesEngine() async throws {
        let harness = Harness(terms: ["Anthropic", "Plainsay"])
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        #expect(harness.engine.receivedPrompt == "Glossary: Anthropic, Plainsay.")
    }

    @Test("Dictation is refused while the speech model is still loading")
    func refusesBeforeModelIsReady() async throws {
        let harness = Harness()
        // Deliberately skip `ready()`.

        harness.dictate()
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.inserter.inserted.isEmpty)
        #expect(!harness.recorder.isRecording)
    }

    @Test("Every dictation is written to history, so a failed paste loses nothing")
    func historyRecordsDictation() async throws {
        let harness = Harness()
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        let last = try #require(harness.history.mostRecent)
        #expect(last.text == "The thing is, it works.")
        // The unpolished version survives too, in case cleanup mangled it.
        #expect(last.rawText == "um so the thing is uh it works")
        #expect(last.outcome == .inserted)
    }

    @Test("History is written even when cleanup fell back to raw")
    func historyRecordsRawFallback() async throws {
        let harness = Harness()
        harness.cleaner.error = CleanupError.timedOut
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        #expect(harness.history.mostRecent?.outcome == .insertedWithoutCleanup)
    }

    @Test("Silent drops are recorded rather than vanishing without trace")
    func historyRecordsSilentDrops() async throws {
        let harness = Harness()
        harness.recorder.duration = 0.1
        await harness.ready()

        harness.dictate(holdFor: 0.5)
        try await Task.sleep(for: .milliseconds(150))

        // Nothing was inserted, but the attempt is visible — "I spoke and
        // nothing happened" needs to be distinguishable from "key misfired".
        #expect(harness.history.mostRecent?.outcome == .tooShort)
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("A tap latches recording on rather than stopping it")
    func tapLatchesThroughCoordinator() async throws {
        let harness = Harness()
        await harness.ready()

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        harness.coordinator.handleHotkeyEdge(.up(at: 0.05))

        #expect(harness.coordinator.phase == .recording)
        #expect(harness.recorder.isRecording)

        harness.coordinator.handleHotkeyEdge(.down(at: 3))
        try await harness.settle()

        #expect(harness.inserter.inserted.count == 1)
    }
}
