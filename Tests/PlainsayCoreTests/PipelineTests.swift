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

/// A deterministic suspension point for lifecycle race tests.
private actor AsyncTestGate {
    private var isOpen = false
    private var hasStarted = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    var started: Bool { hasStarted }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor AsyncCompletionFlag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}

private actor ControlledLoadingEngine: TranscriptionEngine {
    private let gate: AsyncTestGate
    private let transcript: String
    private let onStateChange: @Sendable (SpeechModelLoadState) -> Void
    private(set) var shutdownCount = 0

    init(
        gate: AsyncTestGate,
        transcript: String,
        onStateChange: @escaping @Sendable (SpeechModelLoadState) -> Void
    ) {
        self.gate = gate
        self.transcript = transcript
        self.onStateChange = onStateChange
    }

    func prepare() async throws {
        onStateChange(.loading)
        await gate.wait()
        onStateChange(.ready)
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        transcript
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

@MainActor
private final class LoadingEngineBox {
    var old: ControlledLoadingEngine?
    var latest: ControlledLoadingEngine?
}

private actor ControlledTranscriptionEngine: TranscriptionEngine {
    private let gate: AsyncTestGate
    private(set) var shutdownCount = 0

    init(gate: AsyncTestGate) {
        self.gate = gate
    }

    func prepare() async throws {}

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        await gate.wait()
        return "The dictation survived the model change."
    }

    func shutdown() async {
        shutdownCount += 1
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
            makeCleaner: { _ in cleaner },
            usesInjectedEngine: true
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

    @Test("Superseded model loads finish before the latest one starts")
    func serializesRapidModelReloads() async throws {
        let defaults = UserDefaults(suiteName: "plainsay.reloads.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: defaults)
        settings.playFeedbackSounds = false

        let oldGate = AsyncTestGate()
        let newGate = AsyncTestGate()
        let engines = LoadingEngineBox()
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("reload-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("reload-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { model, _, onState in
                let isOld = model == .largeV3Turbo
                let engine = ControlledLoadingEngine(
                    gate: isOld ? oldGate : newGate,
                    transcript: isOld ? "old" : "new",
                    onStateChange: onState
                )
                if isOld {
                    engines.old = engine
                } else {
                    engines.latest = engine
                }
                return engine
            },
            makeCleaner: { _ in NoCleanup() },
            usesInjectedEngine: true
        )

        let oldLoadCompleted = AsyncCompletionFlag()
        let oldLoad = Task {
            await coordinator.reloadModel()
            await oldLoadCompleted.set()
        }
        await oldGate.waitUntilStarted()
        try await waitForModelState(.loading, coordinator: coordinator)

        settings.model = .smallEN
        let latestLoad = Task { await coordinator.reloadModel() }
        try await waitForModelState(.idle, coordinator: coordinator)

        #expect(!(await newGate.started))
        await oldGate.open()
        await newGate.waitUntilStarted()
        try await waitForModelState(.loading, coordinator: coordinator)
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await oldLoadCompleted.isSet))
        let oldEngine = try #require(engines.old)
        #expect(await oldEngine.shutdownCount == 1)

        await newGate.open()
        await oldLoad.value
        await latestLoad.value

        #expect(coordinator.modelState == .ready)
        let newEngine = try #require(engines.latest)
        #expect(await newEngine.shutdownCount == 0)
    }

    @Test("A reload waits for an active transcription and blocks overlap")
    func reloadWaitsForTranscription() async throws {
        let settings = isolatedSettings("transcription-reload")
        let recorder = FakeRecorder()
        let inserter = FakeInserter()
        let gate = AsyncTestGate()
        let engine = ControlledTranscriptionEngine(gate: gate)
        let coordinator = makeLifecycleCoordinator(
            settings: settings,
            recorder: recorder,
            inserter: inserter,
            engine: engine,
            name: "transcription-reload"
        )
        await coordinator.reloadModel()

        coordinator.handleHotkeyEdge(.down(at: 0))
        coordinator.handleHotkeyEdge(.up(at: 1))
        await gate.waitUntilStarted()

        // A new press while the decoder is busy must not start another capture.
        coordinator.handleHotkeyEdge(.down(at: 2))
        #expect(!recorder.isRecording)

        let reload = Task { await coordinator.reloadModel() }
        try await waitForModelState(.idle, coordinator: coordinator)
        #expect(await engine.shutdownCount == 0)

        await gate.open()
        await reload.value

        #expect(inserter.inserted == ["The dictation survived the model change."])
        #expect(await engine.shutdownCount == 1)
        #expect(coordinator.modelState == .ready)
    }

    @Test("Changing models while recording preserves that recording")
    func reloadWaitsForRecording() async throws {
        let settings = isolatedSettings("recording-reload")
        let recorder = FakeRecorder()
        let inserter = FakeInserter()
        let gate = AsyncTestGate()
        await gate.open()
        let engine = ControlledTranscriptionEngine(gate: gate)
        let coordinator = makeLifecycleCoordinator(
            settings: settings,
            recorder: recorder,
            inserter: inserter,
            engine: engine,
            name: "recording-reload"
        )
        await coordinator.reloadModel()

        coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(coordinator.phase == .recording)

        let reload = Task { await coordinator.reloadModel() }
        try await waitForModelState(.idle, coordinator: coordinator)
        #expect(await engine.shutdownCount == 0)

        coordinator.handleHotkeyEdge(.up(at: 1))
        await reload.value

        #expect(inserter.inserted == ["The dictation survived the model change."])
        #expect(await engine.shutdownCount == 1)
        #expect(coordinator.modelState == .ready)
    }

    @Test("Stopping after key-up does not release a queued transcription")
    func stopKeepsQueuedPipelineOwnership() async throws {
        let settings = isolatedSettings("stop-reload-race")
        let recorder = FakeRecorder()
        let inserter = FakeInserter()
        let gate = AsyncTestGate()
        let engine = ControlledTranscriptionEngine(gate: gate)
        let coordinator = makeLifecycleCoordinator(
            settings: settings,
            recorder: recorder,
            inserter: inserter,
            engine: engine,
            name: "stop-reload-race"
        )
        await coordinator.reloadModel()

        coordinator.handleHotkeyEdge(.down(at: 0))
        coordinator.handleHotkeyEdge(.up(at: 1))
        coordinator.stop()

        let reload = Task { await coordinator.reloadModel() }
        await gate.waitUntilStarted()
        try await waitForModelState(.idle, coordinator: coordinator)
        #expect(await engine.shutdownCount == 0)

        await gate.open()
        await reload.value

        #expect(inserter.inserted == ["The dictation survived the model change."])
        #expect(await engine.shutdownCount == 1)
    }

    private func isolatedSettings(_ name: String) -> PlainsaySettings {
        let defaults = UserDefaults(suiteName: "plainsay.\(name).\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: defaults)
        settings.playFeedbackSounds = false
        return settings
    }

    private func makeLifecycleCoordinator(
        settings: PlainsaySettings,
        recorder: FakeRecorder,
        inserter: FakeInserter,
        engine: any TranscriptionEngine,
        name: String
    ) -> DictationCoordinator {
        DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("\(name)-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("\(name)-pending")),
            recorder: recorder,
            inserter: inserter,
            makeEngine: { _, _, _ in engine },
            makeCleaner: { _ in NoCleanup() },
            usesInjectedEngine: true
        )
    }

    private func temporaryDirectory(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-\(name)-\(UUID().uuidString)")
    }

    private func waitForModelState(
        _ expected: SpeechModelLoadState,
        coordinator: DictationCoordinator
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if coordinator.modelState == expected { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(coordinator.modelState == expected)
    }
}
