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
    /// Every call, including ones currently suspended on the gate below —
    /// incremented before gating, so a test can prove a later call hasn't
    /// even been *entered* yet, not just that it hasn't returned.
    private(set) var callCount = 0
    private var shouldGateNextCall = false
    private var gateContinuation: CheckedContinuation<Void, Never>?

    /// The next `transcribe()` call suspends indefinitely instead of
    /// returning, until `releaseGate()` is called. Pins a specific pass
    /// "still in flight" deterministically, instead of racing real
    /// wall-clock timing against fakes that are otherwise near-instant.
    func gateNextCall() { shouldGateNextCall = true }

    func releaseGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func prepare() async throws {}

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        callCount += 1
        if shouldGateNextCall {
            shouldGateNextCall = false
            await withCheckedContinuation { gateContinuation = $0 }
        }
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

    func clean(_ transcript: String, dictionary: TermDictionary) async throws -> String {
        received = transcript
        if let error { throw error }
        return output
    }
}

@MainActor
final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    private(set) var deletedCounts: [Int] = []
    var outcome: TextInsertionOutcome = .inserted

    func insert(_ text: String, keepOnClipboard: Bool) async -> TextInsertionOutcome {
        inserted.append(text)
        return outcome
    }

    func deleteBackward(_ count: Int) async {
        deletedCounts.append(count)
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

    @Test("Live typing stays off by default, even while recording")
    func liveTypingOffByDefault() async throws {
        let harness = Harness()
        harness.recorder.duration = 3
        harness.engine.transcript = "hello there"
        await harness.ready()

        let previous = DictationCoordinator.previewInterval
        DictationCoordinator.previewInterval = .milliseconds(10)
        defer { DictationCoordinator.previewInterval = previous }

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.inserter.deletedCounts.isEmpty)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()

        // The one, single-shot insert at the end — unchanged from the
        // non-live-typing pipeline.
        #expect(harness.inserter.inserted.count == 1)
        #expect(harness.inserter.deletedCounts.isEmpty)
    }

    @Test("Live typing types the raw preview as it arrives, then reconciles with a minimal edit")
    func liveTypingReconcilesWithMinimalEdit() async throws {
        let harness = Harness()
        harness.settings.liveTypingEnabled = true
        harness.recorder.duration = 3
        harness.engine.transcript = "hello there"
        harness.cleaner.output = "hello there."
        await harness.ready()

        let previous = DictationCoordinator.previewInterval
        DictationCoordinator.previewInterval = .milliseconds(10)
        defer { DictationCoordinator.previewInterval = previous }

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        try await harness.waitUntil { harness.inserter.inserted.contains("hello there") }
        // The raw preview pass typed directly into the document — no HUD
        // preview needed, since live typing doesn't require livePreviewEnabled.
        #expect(harness.inserter.inserted.contains("hello there"))
        #expect(harness.coordinator.livePreviewText.isEmpty)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()

        // Cleanup only added a trailing period. Reconciliation appended just
        // that — it never deleted and retyped words cleanup left untouched.
        #expect(harness.inserter.deletedCounts.isEmpty)
        #expect(harness.inserter.inserted.last == ".")
    }

    @Test("Live typing reconciles by deleting only the diverged tail, not the whole line")
    func liveTypingDeletesOnlyTheDivergedTail() async throws {
        let harness = Harness()
        harness.settings.liveTypingEnabled = true
        harness.recorder.duration = 3
        harness.engine.transcript = "the cat sat"
        harness.cleaner.output = "The cat sat."
        await harness.ready()

        let previous = DictationCoordinator.previewInterval
        DictationCoordinator.previewInterval = .milliseconds(10)
        defer { DictationCoordinator.previewInterval = previous }

        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        try await harness.waitUntil { harness.inserter.inserted.contains("the cat sat") }
        #expect(harness.inserter.inserted.contains("the cat sat"))

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()

        // "the cat sat" -> "The cat sat." diverges at the very first
        // character (case), so the whole line is deleted and retyped rather
        // than nothing at all — proving the delta is computed, not skipped.
        #expect(harness.inserter.deletedCounts == [11])
        #expect(harness.inserter.inserted.last == "The cat sat.")
    }

    @Test("Ending a recording waits for an in-flight live-typing preview pass before starting the final reconciliation")
    func liveTypingWaitsForInFlightPreviewBeforeFinalReconciliation() async throws {
        let harness = Harness()
        harness.settings.liveTypingEnabled = true
        harness.recorder.duration = 3
        harness.engine.transcript = "hello there"
        await harness.ready()

        let previous = DictationCoordinator.previewInterval
        DictationCoordinator.previewInterval = .milliseconds(10)
        defer { DictationCoordinator.previewInterval = previous }

        harness.coordinator.handleHotkeyEdge(.down(at: 0))

        // Let the first preview pass complete normally.
        try await harness.waitUntil { harness.inserter.inserted.contains("hello there") }
        #expect(harness.engine.callCount == 1)

        // Arm the gate, then wait for the SECOND preview tick to actually
        // enter (not return from) transcribe — call 2. From this point on
        // we know, with certainty rather than luck, that a preview pass is
        // suspended mid-flight, because nothing can make it return without
        // `releaseGate()` below.
        harness.engine.gateNextCall()
        try await harness.waitUntil { harness.engine.callCount == 2 }

        // End the recording while that pass is provably still in flight.
        harness.coordinator.handleHotkeyEdge(.up(at: 1))

        // Give the pipeline every chance to race ahead if nothing were
        // actually blocking it. Before the fix, `endRecording` span a new
        // Task that called `process(samples)` — and hence the final
        // engine.transcribe — immediately, regardless of the still-gated
        // preview pass; call count would climb to 3 well within this
        // window. With the fix, the new Task's first move is `await
        // inFlightPreview?.value`, which cannot resolve until the gate is
        // released, so call count must hold at exactly 2 throughout.
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.engine.callCount == 2)

        // Release the gate: the preview pass finishes, and only now should
        // the final reconciliation's own transcribe call be allowed to fire.
        harness.engine.releaseGate()
        try await harness.waitUntil(timeout: .seconds(3)) { harness.engine.callCount == 3 }
        try await harness.settle(timeout: .seconds(3))

        #expect(harness.coordinator.phase == .idle)
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

        settings.model = .smallEN
        let latestLoad = Task { await coordinator.reloadModel() }
        try await waitForModelState(.idle, coordinator: coordinator)

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
        let coordinator = DictationCoordinator(
            settings: settings,
            history: TranscriptHistory(directory: temporaryDirectory("model-failure-history")),
            pendingAudio: PendingAudioStore(directory: temporaryDirectory("model-failure-pending")),
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, onState in
                ControlledFailingLoadingEngine(gate: gate, onStateChange: onState)
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

@Suite("Live-typing diff")
struct LiveTypingDiffTests {
    @Test("A pure extension inserts only the new suffix")
    func appendOnly() {
        let result = DictationCoordinator.diff(from: "hello", to: "hello there")
        #expect(result.deleteCount == 0)
        #expect(result.insertText == " there")
    }

    @Test("A revised tail deletes only the diverged part")
    func revisedTail() {
        let result = DictationCoordinator.diff(from: "the cat sat", to: "the cat sang")
        #expect(result.deleteCount == 1)
        #expect(result.insertText == "ng")
    }

    @Test("Identical text is a no-op")
    func identical() {
        let result = DictationCoordinator.diff(from: "same", to: "same")
        #expect(result.deleteCount == 0)
        #expect(result.insertText.isEmpty)
    }

    @Test("No shared prefix deletes everything and retypes")
    func totalReplacement() {
        let result = DictationCoordinator.diff(from: "abc", to: "xyz")
        #expect(result.deleteCount == 3)
        #expect(result.insertText == "xyz")
    }

    @Test("An empty starting point just types the new text")
    func fromEmpty() {
        let result = DictationCoordinator.diff(from: "", to: "hello")
        #expect(result.deleteCount == 0)
        #expect(result.insertText == "hello")
    }

    @Test("An empty result deletes everything and types nothing")
    func toEmpty() {
        let result = DictationCoordinator.diff(from: "hello", to: "")
        #expect(result.deleteCount == 5)
        #expect(result.insertText.isEmpty)
    }
}

@Suite("Live typing / cleanup exclusivity")
@MainActor
struct LiveTypingCleanupExclusivityTests {
    @Test("Turning on live typing forces cleanup off")
    func liveTypingForcesCleanupOff() {
        let suite = UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: suite)
        settings.cleanupEnabled = true

        settings.liveTypingEnabled = true
        #expect(settings.cleanupEnabled == false)
    }

    @Test("Turning live typing back off does not silently re-enable cleanup")
    func liveTypingOffDoesNotRestoreCleanup() {
        let suite = UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: suite)
        settings.cleanupEnabled = true
        settings.liveTypingEnabled = true
        #expect(settings.cleanupEnabled == false)

        settings.liveTypingEnabled = false
        #expect(settings.cleanupEnabled == false)
    }

    @Test("Turning on cleanup does not affect live typing")
    func cleanupDoesNotForceLiveTypingOff() {
        let suite = UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: suite)
        settings.liveTypingEnabled = false
        settings.cleanupEnabled = true
        #expect(settings.liveTypingEnabled == false)
    }
}
