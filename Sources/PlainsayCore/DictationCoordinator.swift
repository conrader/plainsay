import AppKit
import AVFoundation
import Foundation
import Observation

/// Wires hotkey → audio → transcription → cleanup → insertion, and owns the
/// state the HUD renders.
@MainActor
@Observable
public final class DictationCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case cleaning
        /// Finished, but cleanup fell back to the raw transcript.
        case insertedRaw
        case error(String)

        public var isBusy: Bool {
            switch self {
            case .recording, .transcribing, .cleaning: true
            case .idle, .insertedRaw, .error: false
            }
        }
    }

    /// Anything shorter than this was a mis-tap, not a dictation.
    static let minimumDuration: TimeInterval = 0.3

    public private(set) var phase: Phase = .idle
    /// 0...1, drives the HUD level meter.
    public private(set) var level: Float = 0
    /// Rolling window of recent levels, oldest first. The HUD draws this as a
    /// ribbon so you can see the shape of the sentence you just spoke.
    public private(set) var levelHistory: [Float] = []
    public private(set) var elapsed: TimeInterval = 0

    /// How many samples the ribbon shows — about four seconds at 30fps.
    public static let levelHistoryLength = 120
    public private(set) var modelState: SpeechModelLoadState = .idle
    public private(set) var lastTranscript: String?

    /// Every dictation, written down before insertion is attempted.
    public let history: TranscriptHistory
    /// Captured audio, staged on disk until transcription completes.
    private let pendingAudio: PendingAudioStore
    /// Subscription and credential client for the hosted plan.
    public let cloud: PlainsayCloudClient

    private let settings: PlainsaySettings
    private let recorder: any AudioRecording
    private let inserter: any TextInserting
    private var engine: (any TranscriptionEngine)?
    /// Recording, transcription, and crash recovery all retain the current
    /// engine. A model change waits until every such use has finished.
    private var activeEngineWork = 0
    private var engineIdleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Reloads form a short serial queue. This prevents an old FluidAudio
    /// cleanup from racing a newer model load through its shared Core ML cache.
    private var modelReloadTask: Task<Void, Never>?
    /// Invalidates progress and completion from superseded model loads.
    private var modelLoadGeneration: UInt64 = 0
    private let makeEngine: @MainActor (OnDeviceModel, String?, @escaping @Sendable (SpeechModelLoadState) -> Void) -> any TranscriptionEngine
    private let makeCleaner: @MainActor (PlainsaySettings) -> any TextCleaning
    /// Tests pass a fake engine; production resolves one from settings.
    private let usesInjectedEngine: Bool

    private let hotkeys: HotkeyMonitor
    private var machine: HotkeyStateMachine
    private var meterTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?

    public init(
        settings: PlainsaySettings = .shared,
        history: TranscriptHistory = TranscriptHistory(),
        pendingAudio: PendingAudioStore = PendingAudioStore(),
        cloud: PlainsayCloudClient = PlainsayCloudClient(),
        recorder: any AudioRecording = AudioRecorder(),
        inserter: any TextInserting = PasteboardTextInserter(),
        makeEngine: @escaping @MainActor (OnDeviceModel, String?, @escaping @Sendable (SpeechModelLoadState) -> Void) -> any TranscriptionEngine = { _, _, _ in
            // Replaced below; the real construction needs the whole settings
            // object, not just the model, now that the engine can be remote.
            WhisperKitEngine()
        },
        makeCleaner: @escaping @MainActor (PlainsaySettings) -> any TextCleaning = ProviderFactory.makeCleaner,
        usesInjectedEngine: Bool = false
    ) {
        self.settings = settings
        self.history = history
        self.pendingAudio = pendingAudio
        self.cloud = cloud
        self.recorder = recorder
        self.inserter = inserter
        self.makeEngine = makeEngine
        self.makeCleaner = makeCleaner
        self.usesInjectedEngine = usesInjectedEngine
        self.hotkeys = HotkeyMonitor(binding: settings.binding)
        self.machine = HotkeyStateMachine(mode: settings.hotkeyMode)

        hotkeys.onEdge = { [weak self] edge in
            self?.handle(edge)
        }
    }

    // MARK: - Lifecycle

    /// Starts listening and loads the speech model. Safe to call repeatedly.
    public func start() async {
        // Ask for the microphone here, at launch, while nothing is happening.
        // The System Settings Microphone pane has no "+" button, so the system
        // prompt is the *only* way this grant can ever be given — and if we
        // wait until the first hotkey press to ask, the prompt steals focus
        // mid-sentence and that dictation is lost regardless of the answer.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await Permission.microphone.request()
        }

        // Credentials before the engine is built, or the factory has nothing to
        // work with and Cloud reports itself unavailable on a cold launch.
        await refreshCloudCredentialsIfNeeded()

        do {
            try hotkeys.start()
        } catch {
            phase = .error(error.localizedDescription)
        }
        await reloadModel()
        await recoverInterruptedAudio()
    }

    /// Transcribes audio that a previous run captured but never processed.
    ///
    /// Deliberately does not paste: by now the focus is somewhere else entirely,
    /// and a surprise paste minutes later is worse than none. The text lands in
    /// history, where it can be copied.
    private func recoverInterruptedAudio() async {
        let pending = pendingAudio.recoverable()
        guard !pending.isEmpty,
              case .ready = modelState,
              let engine
        else { return }
        beginEngineWork()
        defer { finishEngineWork() }
        Log.pipeline.info("recovering \(pending.count, privacy: .public) interrupted recording(s)")

        for url in pending {
            guard let samples = pendingAudio.load(url), !samples.isEmpty else {
                pendingAudio.discard(url)
                continue
            }
            let duration = Double(samples.count) / whisperSampleRate
            guard duration >= Self.minimumDuration else {
                pendingAudio.discard(url)
                continue
            }

            let raw: String
            do {
                raw = try await engine.transcribe(
                    samples: samples,
                    prompt: settings.dictionary.asrPrompt()
                )
            } catch {
                // Keep recoverable audio on disk if the model is unavailable or
                // transiently fails. Deleting it here would turn a load race
                // into permanent dictation loss.
                Log.pipeline.error("recovery transcription failed; keeping audio: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard !raw.isEmpty else {
                pendingAudio.discard(url)
                continue
            }

            let cleaned = (try? await makeCleaner(settings).clean(raw, dictionary: settings.dictionary)) ?? raw
            history.add(TranscriptRecord(
                text: cleaned, rawText: raw, outcome: .recovered,
                durationSeconds: duration, targetApp: nil
            ))
            pendingAudio.discard(url)
            Log.pipeline.info("recovered \(cleaned.count, privacy: .public) chars from an interrupted recording")
        }
    }

    public func stop() {
        // After hotkey-up, `phase` remains `.recording` for one scheduler turn
        // while the queued pipeline takes ownership of this work unit. Only
        // release it here if the recorder itself is still capturing.
        let stoppedDuringRecording = phase == .recording && recorder.isRecording
        hotkeys.stop()
        meterTask?.cancel()
        recorder.cancel()
        machine.reset()
        phase = .idle
        if stoppedDuringRecording { finishEngineWork() }
    }

    /// Applies changed settings without a relaunch.
    public func settingsChanged() {
        hotkeys.binding = settings.binding
        machine.mode = settings.hotkeyMode
    }

    public func reloadModel() async {
        modelLoadGeneration &+= 1
        let generation = modelLoadGeneration
        modelState = .idle

        let previousReload = modelReloadTask
        // Network downloads in FluidAudio are cancellation-aware. Stop a
        // superseded choice immediately, then wait for its orderly teardown
        // before touching the shared Core ML runtime again.
        previousReload?.cancel()
        let reload = Task { @MainActor [weak self] in
            await previousReload?.value
            guard let self,
                  !Task.isCancelled,
                  generation == self.modelLoadGeneration
            else { return }
            await self.performModelReload(generation: generation)
        }
        modelReloadTask = reload

        // A caller such as `start()` must not continue into crash recovery just
        // because its own generation was superseded. Follow the queue until the
        // latest requested model has either become ready or failed.
        var awaitedGeneration = generation
        var awaitedReload = reload
        while true {
            await awaitedReload.value
            guard awaitedGeneration != modelLoadGeneration else { return }
            guard let latestReload = modelReloadTask else { return }
            awaitedGeneration = modelLoadGeneration
            awaitedReload = latestReload
        }
    }

    private func performModelReload(generation: UInt64) async {
        // A settings change can arrive while recording or while the decoder is
        // suspended. Keep that dictation on its original resident model.
        await waitForEngineToBecomeIdle()
        guard !Task.isCancelled, generation == modelLoadGeneration else { return }

        let previousEngine = engine
        engine = nil
        await previousEngine?.shutdown()
        guard !Task.isCancelled, generation == modelLoadGeneration else { return }

        await loadModel(generation: generation)
    }

    /// Fetches the hosted plan's provider keys into memory.
    ///
    /// Only ever called for the Cloud source, so someone dictating on-device
    /// never causes a network call to the subscription service.
    private func refreshCloudCredentialsIfNeeded() async {
        guard settings.transcriptionSource == .cloud, cloud.isSignedIn else {
            ProviderFactory.cloudCredentials = nil
            return
        }

        do {
            let account = try await cloud.refreshAccount()
            guard account.isActive else {
                ProviderFactory.cloudCredentials = nil
                Log.model.info("Plainsay Cloud subscription is \(account.status, privacy: .public)")
                return
            }
            ProviderFactory.cloudCredentials = try await cloud.refreshCredentials()
            Log.model.info("Plainsay Cloud credentials loaded into memory")
        } catch {
            ProviderFactory.cloudCredentials = nil
            Log.model.error("Plainsay Cloud unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadModel(generation: UInt64) async {
        let onState: @Sendable (SpeechModelLoadState) -> Void = { [weak self] state in
            Task { @MainActor in
                guard let self, self.modelLoadGeneration == generation else { return }
                self.modelState = state
            }
        }
        // Tests inject `makeEngine`; production goes through the factory, which
        // is the only thing that knows about remote providers.
        let engine = usesInjectedEngine
            ? makeEngine(settings.model, settings.language, onState)
            : ProviderFactory.makeEngine(settings, onState: onState)
        guard !Task.isCancelled, generation == modelLoadGeneration else { return }
        self.engine = engine
        do {
            try await engine.prepare()
            guard generation == modelLoadGeneration else {
                self.engine = nil
                await engine.shutdown()
                return
            }
            // Don't depend on the engine having reported readiness itself —
            // a successful `prepare()` is the definition of ready.
            modelState = .ready
        } catch {
            guard generation == modelLoadGeneration else {
                self.engine = nil
                await engine.shutdown()
                return
            }
            modelState = .failed(error.localizedDescription)
        }
    }

    /// What to say when someone presses the hotkey before the model is up.
    private var modelStatusMessage: String {
        switch modelState {
        case .idle:
            "Starting the speech model…"
        case .downloading:
            "Downloading the speech model (\(settings.model.approximateSize)). This happens once."
        case .loading:
            // The Neural Engine compile runs once per model and takes minutes.
            // Quitting restarts it from scratch, so say not to.
            "Preparing the speech model for the Neural Engine. This takes a few minutes the first time — leave Plainsay running."
        case .ready:
            "Ready"
        case .failed(let message):
            "Speech model failed to load: \(message)"
        }
    }

    // MARK: - Hotkey

    /// Feeds a press or release into the pipeline. Called by the hotkey monitor;
    /// exposed so the flow can be driven directly in tests.
    public func handleHotkeyEdge(_ edge: HotkeyEdge) {
        handle(edge)
    }

    private func handle(_ edge: HotkeyEdge) {
        switch machine.handle(edge) {
        case .start: beginRecording()
        case .stop: endRecording()
        case .none: break
        }
    }

    private func beginRecording() {
        resetTask?.cancel()

        // One dictation at a time. In particular, do not start recording while
        // the previous sentence is still transcribing or being cleaned.
        guard !phase.isBusy, activeEngineWork == 0 else {
            machine.reset()
            return
        }

        guard case .ready = modelState else {
            // Be specific about which wait this is. The first launch after a
            // model change compiles for the Neural Engine, which takes minutes,
            // not seconds — "still loading" leaves you guessing whether to wait
            // or restart, and restarting throws the compile away.
            flashError(modelStatusMessage)
            machine.reset()
            return
        }

        // If the microphone was never granted, asking is more useful than
        // failing. `AudioRecorder.start()` would just throw here.
        guard AudioRecorder.microphoneAuthorized() else {
            flashError("Plainsay needs microphone access")
            Task { await Permission.microphone.request() }
            machine.reset()
            return
        }

        // Captured now, not at insertion time: by the time we paste, the HUD or
        // a notification may have shuffled the frontmost app.
        targetApp = NSWorkspace.shared.frontmostApplication

        do {
            try recorder.start()
        } catch {
            flashError(error.localizedDescription)
            machine.reset()
            return
        }

        phase = .recording
        beginEngineWork()
        elapsed = 0
        // Cleared here rather than on stop, so the ribbon stays frozen on the
        // sentence you just spoke while it transcribes.
        levelHistory = []
        playSound("Tink")
        startMetering()
    }

    private func endRecording() {
        stopMetering()
        let samples = recorder.stop()
        guard phase == .recording else { return }

        let duration = Double(samples.count) / whisperSampleRate
        guard duration >= Self.minimumDuration else {
            // A stray tap. Say nothing, do nothing — but leave a trace, because
            // "I definitely spoke and nothing happened" and "the key barely
            // registered" look identical from the outside.
            Log.pipeline.info("discarded \(duration, format: .fixed(precision: 2), privacy: .public)s — below minimum")
            record(text: "", raw: "", outcome: .tooShort, duration: duration)
            phase = .idle
            finishEngineWork()
            return
        }

        Task { await process(samples) }
    }

    // MARK: - Pipeline

    private func process(_ samples: [Float]) async {
        defer { finishEngineWork() }
        // On disk before transcription, deleted after. Whatever survives a
        // crash here is a dictation that was never turned into text.
        let staged = pendingAudio.save(samples)
        defer { pendingAudio.discard(staged) }

        await runPipeline(samples)
    }

    private func beginEngineWork() {
        activeEngineWork += 1
    }

    private func finishEngineWork() {
        guard activeEngineWork > 0 else { return }
        activeEngineWork -= 1
        guard activeEngineWork == 0 else { return }

        let waiters = engineIdleWaiters
        engineIdleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForEngineToBecomeIdle() async {
        guard activeEngineWork > 0 else { return }
        await withCheckedContinuation { continuation in
            engineIdleWaiters.append(continuation)
        }
    }

    private func runPipeline(_ samples: [Float]) async {
        let duration = Double(samples.count) / whisperSampleRate

        guard let engine else {
            record(text: "", raw: "", outcome: .modelNotReady, duration: duration)
            flashError("Speech model not loaded")
            return
        }

        phase = .transcribing
        let prompt = settings.dictionary.asrPrompt()

        let started = Date()
        let transcript: String
        do {
            transcript = try await engine.transcribe(samples: samples, prompt: prompt)
        } catch {
            Log.pipeline.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            record(text: "", raw: "", outcome: .transcriptionFailed, duration: duration)
            flashError(error.localizedDescription)
            return
        }
        Log.pipeline.info("""
            transcribed \(duration, format: .fixed(precision: 1), privacy: .public)s audio \
            in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s, \
            \(transcript.count, privacy: .public) chars
            """)

        guard !transcript.isEmpty else {
            // Whisper heard nothing worth inserting.
            Log.pipeline.info("empty transcript — nothing inserted")
            record(text: "", raw: "", outcome: .silence, duration: duration)
            phase = .idle
            return
        }

        phase = .cleaning
        let dictionary = settings.dictionary
        let cleaner = makeCleaner(settings)

        var finalText = transcript
        var usedRaw = false
        do {
            finalText = try await cleaner.clean(transcript, dictionary: dictionary)
        } catch {
            // Cleanup is best-effort: a failure must never cost the dictation.
            Log.cleanup.error("cleanup failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
            usedRaw = true
            finalText = transcript
        }

        lastTranscript = finalText

        // Written down *before* the paste is attempted. Insertion is the one
        // step we cannot verify, so the history has to survive its failure.
        record(
            text: finalText,
            raw: transcript,
            outcome: usedRaw ? .insertedWithoutCleanup : .inserted,
            duration: duration
        )

        await insert(finalText)

        phase = usedRaw ? .insertedRaw : .idle
        playSound("Pop")
        scheduleReset()
    }

    private func record(text: String, raw: String, outcome: DictationOutcome, duration: Double) {
        history.add(TranscriptRecord(
            text: text,
            rawText: raw,
            outcome: outcome,
            durationSeconds: duration,
            targetApp: targetApp?.bundleIdentifier
        ))
    }

    private func insert(_ text: String) async {
        if let targetApp, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != targetApp.bundleIdentifier {
            // The user switched apps mid-dictation. Paste where they are now —
            // stealing focus back would be more surprising than a stray paste.
            NSLog("[Plainsay] frontmost app changed during dictation; inserting into current app")
        }
        await inserter.insert(text, keepOnClipboard: settings.keepOnClipboard)
        targetApp = nil
    }

    // MARK: - HUD feed

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.recorder.isRecording else { return }
                let level = self.recorder.normalizedLevel
                self.level = level
                self.levelHistory.append(level)
                if self.levelHistory.count > Self.levelHistoryLength {
                    self.levelHistory.removeFirst(self.levelHistory.count - Self.levelHistoryLength)
                }
                self.elapsed = self.recorder.elapsed
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        level = 0
    }

    private func flashError(_ message: String) {
        stopMetering()
        recorder.cancel()
        phase = .error(message)
        scheduleReset(after: .seconds(4))
    }

    private func scheduleReset(after delay: Duration = .seconds(2)) {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.phase.isBusy else { return }
            self.phase = .idle
        }
    }

    private func playSound(_ name: String) {
        guard settings.playFeedbackSounds else { return }
        NSSound(named: name)?.play()
    }
}
