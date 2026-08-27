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
    var hasReachedMaximumDuration = false
    var startError: Error?
    /// Seconds of audio `stop()` will claim to have captured.
    var duration: TimeInterval = 2.0
    private(set) var cancelCount = 0
    private(set) var stopCount = 0

    func start() throws {
        if let startError { throw startError }
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        stopCount += 1
        return [Float](repeating: 0.1, count: Int(duration * whisperSampleRate))
    }

    func cancel() {
        isRecording = false
        cancelCount += 1
    }

    func peek() -> [Float] {
        guard isRecording else { return [] }
        return [Float](repeating: 0.1, count: Int(duration * whisperSampleRate))
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
        onStateChange(.loading(progress: nil))
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

@MainActor
private final class ModelStateCallbackBox {
    var report: (@Sendable (SpeechModelLoadState) -> Void)?
}

@MainActor
private final class ModelLoadTestClock {
    var now: Date

    init(secondsSince1970: TimeInterval = 0) {
        now = Date(timeIntervalSince1970: secondsSince1970)
    }

    func set(_ secondsSince1970: TimeInterval) {
        now = Date(timeIntervalSince1970: secondsSince1970)
    }
}

/// Holds `prepare()` open while a test sends model-state callbacks by hand.
private actor TimingTestEngine: TranscriptionEngine {
    private let gate: AsyncTestGate
    private let failureMessage: String?

    init(gate: AsyncTestGate, failureMessage: String? = nil) {
        self.gate = gate
        self.failureMessage = failureMessage
    }

    func prepare() async throws {
        await gate.wait()
        if let failureMessage {
            throw TranscriptionError.failed(failureMessage)
        }
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        "unused"
    }
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

private actor ControlledFailingLoadingEngine: TranscriptionEngine {
    private let gate: AsyncTestGate
    private let onStateChange: @Sendable (SpeechModelLoadState) -> Void

    init(
        gate: AsyncTestGate,
        onStateChange: @escaping @Sendable (SpeechModelLoadState) -> Void
    ) {
        self.gate = gate
        self.onStateChange = onStateChange
    }

    func prepare() async throws {
        onStateChange(.loading(progress: nil))
        await gate.wait()
        throw TranscriptionError.failed("controlled load failure")
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        throw TranscriptionError.modelNotLoaded
    }
}

final class FakeCleaner: TextCleaning, @unchecked Sendable {
    var output = "The thing is, it works."
    var error: Error?
    private(set) var received: String?
    private(set) var receivedStyle: CleanupStyle?

    func clean(_ transcript: String, dictionary: TermDictionary, style: CleanupStyle) async throws -> String {
        received = transcript
        receivedStyle = style
        if let error { throw error }
        return output
    }
}

@MainActor
final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    var outcome: TextInsertionOutcome = .inserted

    func insert(_ text: String, keepOnClipboard: Bool) async -> TextInsertionOutcome {
        inserted.append(text)
        return outcome
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

    init(
        terms: [String] = [],
        microphoneAuthorized: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
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
            microphoneAuthorized: microphoneAuthorized,
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

    /// Polls until `predicate` is true or `timeout` elapses, instead of a
    /// fixed sleep racing the live-preview loop. A fixed sleep long enough
    /// to be reliable on a fast local machine is still too tight on a loaded
    /// CI runner — see the "Live preview updates while recording" CI
    /// failures this replaced.
    func waitUntil(timeout: Duration = .seconds(2), _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
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

// `.serialized`: a couple of tests below tune the shared, module-wide
// `DictationCoordinator.previewInterval` for the duration of one test rather
// than waiting out its real 1.5s cadence — concurrent tests mutating it would
// race.
@Suite("Dictation pipeline", .serialized)
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

    @Test("A missing microphone grant blocks recording before the recorder starts")
    func missingMicrophonePermissionBlocksRecording() async {
        let harness = Harness(microphoneAuthorized: { false })
        await harness.ready()

        harness.coordinator.handleHotkeyEdge(.down(at: 0))

        #expect(harness.coordinator.phase == .error("Plainsay needs microphone access"))
        #expect(!harness.recorder.isRecording)
        #expect(harness.recorder.stopCount == 0)
    }

    @Test("Reaching the recording boundary stops once and processes every retained sample")
    func recordingLimitStopsAndProcessesCapture() async throws {
        let harness = Harness()
        harness.recorder.duration = 2
        await harness.ready()

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        harness.recorder.hasReachedMaximumDuration = true

        #expect(harness.coordinator.enforceRecordingLimitIfNeeded())
        #expect(harness.coordinator.phase == .recordingLimitReached)
        #expect(!harness.recorder.isRecording)
        #expect(harness.recorder.stopCount == 1)

        // The release from the automatically ended hold is swallowed after
        // the state machine reset and cannot start or stop another capture.
        harness.coordinator.handleHotkeyEdge(.up(at: 600))
        #expect(!harness.recorder.isRecording)
        #expect(!harness.coordinator.enforceRecordingLimitIfNeeded())

        try await harness.settle()

        #expect(harness.engine.receivedSampleCount == Int(2 * whisperSampleRate))
        #expect(harness.inserter.inserted == ["The thing is, it works."])
        #expect(harness.recorder.stopCount == 1)
        #expect(harness.history.mostRecent?.durationSeconds == 2)
    }

    @Test("Live preview stays off by default, even while recording")
    func livePreviewOffByDefault() async throws {
        let harness = Harness()
        harness.recorder.duration = 3
        await harness.ready()

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.coordinator.livePreviewText.isEmpty)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
    }

    @Test("Live preview stays off for a remote provider even when enabled")
    func livePreviewSkipsRemoteSources() async throws {
        let harness = Harness()
        harness.settings.livePreviewEnabled = true
        harness.settings.transcriptionSource = .remote
        harness.recorder.duration = 3
        await harness.ready()

        let previous = DictationCoordinator.previewInterval
        DictationCoordinator.previewInterval = .milliseconds(10)
        defer { DictationCoordinator.previewInterval = previous }

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.coordinator.livePreviewText.isEmpty)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
    }

    @Test("Live preview updates while recording, then clears once it stops")
    func livePreviewUpdatesWhileRecording() async throws {
        let harness = Harness()
        harness.settings.livePreviewEnabled = true
        harness.recorder.duration = 3
        harness.engine.transcript = "hello there"
        await harness.ready()

        let previous = DictationCoordinator.previewInterval
        DictationCoordinator.previewInterval = .milliseconds(10)
        defer { DictationCoordinator.previewInterval = previous }

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.phase == .recording)

        try await harness.waitUntil { harness.coordinator.livePreviewText == "hello there" }
        #expect(harness.coordinator.livePreviewText == "hello there")
        // Purely a HUD readout — the loop never touches what's actually
        // inserted or written to history.
        #expect(harness.inserter.inserted.isEmpty)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()

        #expect(harness.coordinator.livePreviewText.isEmpty)
    }

    @Test("Voice filtering enabled but not yet loaded fails open — dictation still works")
    func voiceFilterFailsOpenWhenNotLoaded() async throws {
        let harness = Harness()
        harness.settings.voiceFilterEnabled = true
        // Never enrolled, never loaded — this is what every dictation sees
        // in the window between flipping the toggle and the filter actually
        // finishing its own model download.
        await harness.ready()

        harness.dictate()
        try await harness.settle()

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

    @Test("Control characters from Polishing never reach the paste")
    func cleanupOutputIsSanitizedBeforeInsertion() async throws {
        // Polishing is a remote LLM's output, not a fixed local transform —
        // nothing guarantees it never contains a stray control byte. A
        // synthetic ⌘V carries whatever a string contains straight to
        // whatever is focused; into a terminal, ESC begins a control
        // sequence the terminal itself will act on.
        let harness = Harness()
        harness.cleaner.output = "line one\u{1B}[31mline two\u{0007}\r\nline three"
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        // \n and \t survive — real paragraph/tab formatting Polishing is
        // asked to produce — everything else in the control ranges does not.
        #expect(harness.inserter.inserted == ["line one[31mline two\nline three"])
    }

    @Test("No focused element saves the dictation to the clipboard instead of losing it")
    func noFocusedElementSavesToClipboard() async throws {
        let harness = Harness()
        harness.inserter.outcome = .noFocusedElement
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        // Still written to the clipboard and to history — only where it
        // landed changes, not whether the dictation survived.
        #expect(harness.inserter.inserted == ["The thing is, it works."])
        #expect(harness.coordinator.phase == .savedToClipboard)
        #expect(harness.coordinator.lastInsertionNeedsManualPaste)
        #expect(harness.history.mostRecent?.outcome == .insertionUnverified)

        // A later successful insertion resolves the persistent recovery
        // notice without rewriting the earlier history record.
        harness.inserter.outcome = .inserted
        harness.dictate()
        try await harness.settle()
        #expect(!harness.coordinator.lastInsertionNeedsManualPaste)
        #expect(harness.history.mostRecent?.outcome == .inserted)
        #expect(harness.history.records.contains { $0.outcome == .insertionUnverifiedAcknowledged })
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
        try await harness.waitUntil {
            if case .error = harness.coordinator.phase { return true }
            return false
        }

        #expect(harness.inserter.inserted.isEmpty)
        if case .error = harness.coordinator.phase {} else {
            Issue.record("expected an error phase, got \(harness.coordinator.phase)")
        }

        // A model lifecycle success is unrelated to this transcription error
        // and must not erase its persistent recovery notice.
        let persistentError = try #require(harness.coordinator.lastErrorMessage)
        await harness.coordinator.reloadModel()
        #expect(harness.coordinator.modelState == .ready)
        #expect(harness.coordinator.lastErrorMessage == persistentError)
    }

    @Test("The vocabulary reaches the speech model as a decoder prompt")
    func vocabularyReachesEngine() async throws {
        let harness = Harness(terms: ["Anthropic", "Plainsay"])
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        #expect(harness.engine.receivedPrompt == "This recording may mention Anthropic and Plainsay.")
    }

    @Test("Vocabulary corrections apply to the transcript before editing ever sees it")
    func vocabularyCorrectsTranscriptBeforeEditing() async throws {
        // Parakeet has no decoder prompt at all, so this correction is the
        // only path a dictionary term has to a fixed spelling once editing
        // is off — and running it unconditionally, before editing, means
        // editing also benefits from the corrected spelling when it is on.
        let harness = Harness(terms: ["Plainsay"])
        harness.engine.transcript = "i use plain say daily"
        await harness.ready()

        harness.dictate()
        try await harness.settle()

        #expect(harness.cleaner.received == "i use Plainsay daily")
    }

    @Test("Dictation is refused while the speech model is still loading")
    func refusesBeforeModelIsReady() async throws {
        let harness = Harness()
        // Deliberately skip `ready()`.

        harness.dictate()
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.inserter.inserted.isEmpty)
        #expect(!harness.recorder.isRecording)
        #expect(harness.coordinator.phase == .modelLoading)
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

    @Test("Escape cancels a latched dictation without processing it")
    func escapeCancelsLatchedDictation() async throws {
        let harness = Harness()
        await harness.ready()

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        harness.coordinator.handleHotkeyEdge(.up(at: 0.05))
        #expect(harness.coordinator.phase == .recording)

        #expect(harness.coordinator.cancelDictation())
        #expect(harness.coordinator.phase == .cancelled)
        #expect(!harness.recorder.isRecording)
        #expect(harness.recorder.cancelCount == 1)
        #expect(harness.engine.receivedSampleCount == 0)
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.history.mostRecent == nil)

        // Cancelling resets the latch, so the next press starts a fresh
        // recording instead of behaving like the old session's stop press.
        harness.coordinator.handleHotkeyEdge(.down(at: 2))
        #expect(harness.coordinator.phase == .recording)
        #expect(harness.recorder.isRecording)
        #expect(harness.coordinator.cancelDictation())
    }

    @Test("Escape cancels a held dictation and strands no key release")
    func escapeCancelsHeldDictation() async throws {
        let harness = Harness()
        await harness.ready()

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.cancelDictation())

        // The release belonging to the abandoned press must not start the
        // pipeline or affect a later recording.
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        #expect(harness.coordinator.phase == .cancelled)
        #expect(harness.engine.receivedSampleCount == 0)
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.history.mostRecent == nil)

        harness.coordinator.handleHotkeyEdge(.down(at: 2))
        #expect(harness.coordinator.phase == .recording)
        #expect(harness.coordinator.cancelDictation())
    }

    @Test("Escape while idle is a no-op")
    func escapeWhileIdleDoesNothing() async {
        let harness = Harness()
        await harness.ready()

        #expect(!harness.coordinator.cancelDictation())
        #expect(harness.coordinator.phase == .idle)
        #expect(harness.recorder.cancelCount == 0)
        #expect(harness.history.mostRecent == nil)
    }

    @Test("Cancelling during live preview keeps the engine until that preview exits")
    func escapeWaitsForInFlightPreviewBeforeReload() async throws {
        let settings = isolatedSettings("cancel-preview-reload")
        settings.livePreviewEnabled = true
        settings.transcriptionSource = .onDevice
        let recorder = FakeRecorder()
        let inserter = FakeInserter()
        let gate = AsyncTestGate()
        let engine = ControlledTranscriptionEngine(gate: gate)
        let coordinator = makeLifecycleCoordinator(
            settings: settings,
            recorder: recorder,
            inserter: inserter,
            engine: engine,
            name: "cancel-preview-reload"
        )
        await coordinator.reloadModel()

        let previous = DictationCoordinator.previewInterval
        DictationCoordinator.previewInterval = .milliseconds(10)
        defer { DictationCoordinator.previewInterval = previous }

        coordinator.handleHotkeyEdge(.down(at: 0))
        await gate.waitUntilStarted()
        #expect(coordinator.cancelDictation())

        let reload = Task { await coordinator.reloadModel() }
        try await waitForModelState(.idle, coordinator: coordinator)
        for _ in 0..<10 { await Task.yield() }
        #expect(await engine.shutdownCount == 0)

        await gate.open()
        await reload.value

        #expect(await engine.shutdownCount == 1)
        #expect(inserter.inserted.isEmpty)
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
        try await waitForModelState(.loading(progress: nil), coordinator: coordinator)
        let existingTiming = try #require(coordinator.modelLoadTiming)

        settings.model = .smallEN
        let latestLoad = Task { await coordinator.reloadModel() }
        await drainModelStateCallbacks()
        #expect(coordinator.modelState == .loading(progress: nil))
        #expect(coordinator.modelLoadTiming == existingTiming)

        #expect(!(await newGate.started))
        await oldGate.open()
        await newGate.waitUntilStarted()
        try await waitForModelState(.loading(progress: nil), coordinator: coordinator)
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

    @Test("Late progress cannot overwrite a completed model load")
    func terminalModelStateIsStickyWithinGeneration() async {
        let settings = isolatedSettings("late-model-progress")
        let callback = ModelStateCallbackBox()
        let engine = FakeEngine()
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("late-progress-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("late-progress-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, onState in
                callback.report = onState
                return engine
            },
            makeCleaner: { _ in NoCleanup() },
            usesInjectedEngine: true
        )

        await coordinator.reloadModel()
        #expect(coordinator.modelState == .ready)

        callback.report?(.downloading(progress: 0.2))
        callback.report?(.loading(progress: nil))
        for _ in 0..<10 { await Task.yield() }

        #expect(coordinator.modelState == .ready)
    }

    @Test("Download timing keeps its start while real progress refreshes liveness")
    func downloadTimingTracksProgressWithoutRestartingPhase() async throws {
        let settings = isolatedSettings("download-timing")
        let callback = ModelStateCallbackBox()
        let clock = ModelLoadTestClock(secondsSince1970: 10)
        let gate = AsyncTestGate()
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("download-timing-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("download-timing-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, onState in
                callback.report = onState
                return TimingTestEngine(gate: gate)
            },
            makeCleaner: { _ in NoCleanup() },
            modelLoadNow: { clock.now },
            usesInjectedEngine: true
        )

        let load = Task { await coordinator.reloadModel() }
        await gate.waitUntilStarted()

        callback.report?(.downloading(progress: 0.1))
        try await waitForModelState(.downloading(progress: 0.1), coordinator: coordinator)
        let startedAt = Date(timeIntervalSince1970: 10)
        #expect(coordinator.modelLoadTiming == SpeechModelLoadTiming(
            phase: .downloading,
            startedAt: startedAt,
            lastDownloadProgressAt: startedAt,
            highestDownloadProgress: 0.1
        ))

        // A duplicate callback is not real progress and must move neither
        // marker, even though the wall clock has advanced.
        clock.set(20)
        callback.report?(.downloading(progress: 0.1))
        await drainModelStateCallbacks()
        #expect(coordinator.modelLoadTiming?.startedAt == startedAt)
        #expect(coordinator.modelLoadTiming?.lastDownloadProgressAt == startedAt)

        // A changed fraction refreshes liveness without restarting the phase.
        clock.set(30)
        callback.report?(.downloading(progress: 0.2))
        try await waitForModelState(.downloading(progress: 0.2), coordinator: coordinator)
        #expect(coordinator.modelLoadTiming?.startedAt == startedAt)
        #expect(coordinator.modelLoadTiming?.lastDownloadProgressAt == Date(timeIntervalSince1970: 30))

        // A provider can briefly report an older aggregate fraction while
        // switching files. That is not forward progress and must not hide a
        // genuinely stalled download.
        clock.set(40)
        callback.report?(.downloading(progress: 0.15))
        try await waitForModelState(.downloading(progress: 0.15), coordinator: coordinator)
        #expect(coordinator.modelLoadTiming?.lastDownloadProgressAt == Date(timeIntervalSince1970: 30))

        // Rising from a regressed subtotal still does not count until the
        // previous all-time high is exceeded.
        clock.set(50)
        callback.report?(.downloading(progress: 0.16))
        try await waitForModelState(.downloading(progress: 0.16), coordinator: coordinator)
        #expect(coordinator.modelLoadTiming?.lastDownloadProgressAt == Date(timeIntervalSince1970: 30))
        #expect(coordinator.modelLoadTiming?.highestDownloadProgress == 0.2)

        clock.set(60)
        callback.report?(.downloading(progress: 0.21))
        try await waitForModelState(.downloading(progress: 0.21), coordinator: coordinator)
        #expect(coordinator.modelLoadTiming?.lastDownloadProgressAt == Date(timeIntervalSince1970: 60))
        #expect(coordinator.modelLoadTiming?.highestDownloadProgress == 0.21)

        await gate.open()
        await load.value
    }

    @Test("Retry keeps a stalled timer visible until the previous load really stops")
    func retryPreservesTimingWhileCancellationUnwinds() async throws {
        let settings = isolatedSettings("retry-preserves-timing")
        let firstCallback = ModelStateCallbackBox()
        let retryCallback = ModelStateCallbackBox()
        let clock = ModelLoadTestClock(secondsSince1970: 10)
        let firstGate = AsyncTestGate()
        let retryGate = AsyncTestGate()
        var buildCount = 0
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("retry-timing-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("retry-timing-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, onState in
                buildCount += 1
                if buildCount == 1 {
                    firstCallback.report = onState
                    return TimingTestEngine(gate: firstGate)
                }
                retryCallback.report = onState
                return TimingTestEngine(gate: retryGate)
            },
            makeCleaner: { _ in NoCleanup() },
            modelLoadNow: { clock.now },
            usesInjectedEngine: true
        )

        let firstLoad = Task { await coordinator.reloadModel() }
        await firstGate.waitUntilStarted()
        firstCallback.report?(.downloading(progress: 0.25))
        try await waitForModelState(.downloading(progress: 0.25), coordinator: coordinator)
        let stalledTiming = try #require(coordinator.modelLoadTiming)

        let retry = Task { await coordinator.retryModel() }
        await drainModelStateCallbacks()
        #expect(coordinator.modelState == .downloading(progress: 0.25))
        #expect(coordinator.modelLoadTiming == stalledTiming)
        #expect(!(await retryGate.started))

        await firstGate.open()
        await retryGate.waitUntilStarted()
        #expect(coordinator.modelState == .idle)
        #expect(coordinator.modelLoadTiming == nil)

        clock.set(40)
        retryCallback.report?(.downloading(progress: 0.1))
        try await waitForModelState(.downloading(progress: 0.1), coordinator: coordinator)
        #expect(coordinator.modelLoadTiming?.startedAt == Date(timeIntervalSince1970: 40))

        await retryGate.open()
        await firstLoad.value
        await retry.value
    }

    @Test("Preparation gets a new start and ready clears model timing")
    func preparationTimingStartsAtPhaseTransitionAndClearsAtReady() async throws {
        let settings = isolatedSettings("preparation-timing")
        let callback = ModelStateCallbackBox()
        let clock = ModelLoadTestClock(secondsSince1970: 10)
        let gate = AsyncTestGate()
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("preparation-timing-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("preparation-timing-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, onState in
                callback.report = onState
                return TimingTestEngine(gate: gate)
            },
            makeCleaner: { _ in NoCleanup() },
            modelLoadNow: { clock.now },
            usesInjectedEngine: true
        )

        let load = Task { await coordinator.reloadModel() }
        await gate.waitUntilStarted()
        callback.report?(.downloading(progress: 0.5))
        try await waitForModelState(.downloading(progress: 0.5), coordinator: coordinator)

        clock.set(40)
        callback.report?(.loading(progress: nil))
        try await waitForModelState(.loading(progress: nil), coordinator: coordinator)
        #expect(coordinator.modelLoadTiming == SpeechModelLoadTiming(
            phase: .preparing,
            startedAt: Date(timeIntervalSince1970: 40),
            lastDownloadProgressAt: nil
        ))

        await gate.open()
        await load.value
        #expect(coordinator.modelState == .ready)
        #expect(coordinator.modelLoadTiming == nil)
    }

    @Test("A failed model load clears model timing")
    func failedModelLoadClearsTiming() async throws {
        let settings = isolatedSettings("failed-model-timing")
        let callback = ModelStateCallbackBox()
        let clock = ModelLoadTestClock(secondsSince1970: 10)
        let gate = AsyncTestGate()
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("failed-model-timing-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("failed-model-timing-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, onState in
                callback.report = onState
                return TimingTestEngine(gate: gate, failureMessage: "timing failure")
            },
            makeCleaner: { _ in NoCleanup() },
            modelLoadNow: { clock.now },
            usesInjectedEngine: true
        )

        let load = Task { await coordinator.reloadModel() }
        await gate.waitUntilStarted()
        callback.report?(.loading(progress: nil))
        try await waitForModelState(.loading(progress: nil), coordinator: coordinator)
        #expect(coordinator.modelLoadTiming != nil)

        await gate.open()
        await load.value
        #expect(coordinator.modelState == .failed("Transcription failed: timing failure"))
        #expect(coordinator.modelLoadTiming == nil)
    }

    @Test("Superseded generation callbacks cannot change current model timing")
    func supersededGenerationCannotChangeModelTiming() async throws {
        let settings = isolatedSettings("superseded-model-timing")
        settings.model = .largeV3Turbo
        let oldCallback = ModelStateCallbackBox()
        let latestCallback = ModelStateCallbackBox()
        let clock = ModelLoadTestClock(secondsSince1970: 10)
        let oldGate = AsyncTestGate()
        let latestGate = AsyncTestGate()
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("superseded-timing-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("superseded-timing-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { model, _, onState in
                if model == .largeV3Turbo {
                    oldCallback.report = onState
                    return TimingTestEngine(gate: oldGate)
                }
                latestCallback.report = onState
                return TimingTestEngine(gate: latestGate)
            },
            makeCleaner: { _ in NoCleanup() },
            modelLoadNow: { clock.now },
            usesInjectedEngine: true
        )

        let oldLoad = Task { await coordinator.reloadModel() }
        await oldGate.waitUntilStarted()
        oldCallback.report?(.downloading(progress: 0.1))
        try await waitForModelState(.downloading(progress: 0.1), coordinator: coordinator)
        let oldTiming = try #require(coordinator.modelLoadTiming)

        settings.model = .smallEN
        let latestLoad = Task { await coordinator.reloadModel() }
        await drainModelStateCallbacks()
        #expect(coordinator.modelState == .downloading(progress: 0.1))
        #expect(coordinator.modelLoadTiming == oldTiming)

        // The old callback is already invalid as soon as the generation
        // changes, even while its cancelled prepare is unwinding.
        clock.set(20)
        oldCallback.report?(.downloading(progress: 0.8))
        await drainModelStateCallbacks()
        #expect(coordinator.modelState == .downloading(progress: 0.1))
        #expect(coordinator.modelLoadTiming == oldTiming)

        await oldGate.open()
        await latestGate.waitUntilStarted()
        clock.set(30)
        latestCallback.report?(.downloading(progress: 0.2))
        try await waitForModelState(.downloading(progress: 0.2), coordinator: coordinator)
        let latestTiming = coordinator.modelLoadTiming

        clock.set(40)
        oldCallback.report?(.loading(progress: nil))
        await drainModelStateCallbacks()
        #expect(coordinator.modelState == .downloading(progress: 0.2))
        #expect(coordinator.modelLoadTiming == latestTiming)

        await latestGate.open()
        await oldLoad.value
        await latestLoad.value
    }

    @Test("The model progress HUD dismisses after loading completes")
    func modelLoadingHUDCompletes() async throws {
        let settings = isolatedSettings("model-hud-completes")
        let gate = AsyncTestGate()
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("model-hud-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("model-hud-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, onState in
                ControlledLoadingEngine(gate: gate, transcript: "unused", onStateChange: onState)
            },
            makeCleaner: { _ in NoCleanup() },
            usesInjectedEngine: true
        )

        let load = Task { await coordinator.reloadModel() }
        await gate.waitUntilStarted()
        try await waitForModelState(.loading(progress: nil), coordinator: coordinator)

        coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(coordinator.phase == .modelLoading)

        await gate.open()
        await load.value
        #expect(coordinator.modelState == .ready)

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, coordinator.phase != .idle {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.phase == .idle)
    }

    @Test("A model load failure replaces progress with an error")
    func modelLoadingHUDFails() async throws {
        let settings = isolatedSettings("model-hud-fails")
        let gate = AsyncTestGate()
        var loadAttempt = 0
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("model-failure-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("model-failure-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, onState -> any TranscriptionEngine in
                loadAttempt += 1
                if loadAttempt == 1 {
                    return ControlledFailingLoadingEngine(gate: gate, onStateChange: onState)
                }
                return FakeEngine()
            },
            makeCleaner: { _ in NoCleanup() },
            usesInjectedEngine: true
        )

        let load = Task { await coordinator.reloadModel() }
        await gate.waitUntilStarted()
        try await waitForModelState(.loading(progress: nil), coordinator: coordinator)
        coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(coordinator.phase == .modelLoading)

        await gate.open()
        await load.value

        if case .error(let message) = coordinator.phase {
            #expect(message.contains("controlled load failure"))
        } else {
            Issue.record("expected model load error, got \(coordinator.phase)")
        }

        // Asking to dictate while the model is failed repeats that model
        // notice. A later successful retry must still recognize and clear it.
        coordinator.handleHotkeyEdge(.down(at: 1))
        #expect(coordinator.lastErrorMessage?.contains("controlled load failure") == true)
        await coordinator.retryModel()
        #expect(coordinator.modelState == .ready)
        #expect(coordinator.lastErrorMessage == nil)
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
            microphoneAuthorized: { true },
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

    private func drainModelStateCallbacks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

/// Email mode's gate (#31).
///
/// `MailTargetTests` proves the detector recognises a mail composer. These
/// prove the feature stays *off* unless it is genuinely switched on and
/// entitled — the half that would cost real users if it were wrong, because it
/// would silently reshape text nobody asked to have reshaped.
@Suite("Email mode gating")
@MainActor
struct EmailModeGatingTests {
    @Test("Ordinary dictation asks for plain prose")
    func defaultsToPlain() async throws {
        let harness = Harness()
        await harness.ready()
        harness.dictate()
        try await harness.settle()

        #expect(harness.cleaner.receivedStyle == .plain)
    }

    @Test("With email mode on but no subscription, dictation stays plain")
    func premiumGateHolds() async throws {
        // Gated on the entitlement, not on which engine runs: cleanup can
        // happen entirely on-device, so a gate keyed off the transcription
        // source would hand the paid feature to every local user for free.
        let harness = Harness()
        harness.settings.emailModeEnabled = true
        await harness.ready()
        harness.dictate()
        try await harness.settle()

        #expect(harness.coordinator.cloud.account?.isActive != true)
        #expect(harness.cleaner.receivedStyle == .plain)
    }
}
