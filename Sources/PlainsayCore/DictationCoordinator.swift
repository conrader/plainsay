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
        /// The hotkey was pressed while the selected speech model was still
        /// downloading or being prepared. The HUD renders `modelState` rather
        /// than treating this as a generic failure.
        case modelLoading
        /// Finished, but cleanup fell back to the raw transcript.
        case insertedRaw
        /// Nothing was focused to paste into. The text is safe on the
        /// clipboard, but it did not land anywhere on its own.
        case savedToClipboard
        case error(String)

        public var isBusy: Bool {
            switch self {
            case .recording, .transcribing, .cleaning: true
            case .idle, .modelLoading, .insertedRaw, .savedToClipboard, .error: false
            }
        }
    }

    /// Anything shorter than this was a mis-tap, not a dictation.
    static let minimumDuration: TimeInterval = 0.3
    /// How often the live preview re-transcribes the growing recording.
    /// A `var`, not `let`, so tests can shrink it rather than waiting out a
    /// real 1.5s cadence.
    static var previewInterval: Duration = .milliseconds(1500)

    public private(set) var phase: Phase = .idle
    /// 0...1, drives the HUD level meter.
    public private(set) var level: Float = 0
    /// Rolling window of recent levels, oldest first. The HUD draws this as a
    /// ribbon so you can see the shape of the sentence you just spoke.
    public private(set) var levelHistory: [Float] = []
    public private(set) var elapsed: TimeInterval = 0
    /// A rough, unedited preview of what's being heard while recording.
    /// Purely a HUD readout — never recorded to history and never what
    /// actually gets inserted; the final pipeline re-transcribes and cleans
    /// the complete recording from scratch once you stop.
    public private(set) var livePreviewText: String = ""

    /// How many samples the ribbon shows — about four seconds at 30fps.
    public static let levelHistoryLength = 120
    public private(set) var modelState: SpeechModelLoadState = .idle
    public private(set) var lastTranscript: String?

    /// The single technical answer to "will the hotkey work right now?" Setup
    /// completion is deliberately not part of this: after the user confirms a
    /// speech choice, the pipeline may already be usable while the assistant is
    /// still open on its final page.
    public var isReadyForDictation: Bool {
        guard modelState == .ready, Permissions.allGranted else { return false }
        if case .error = phase { return false }
        return true
    }

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
    private var previewTask: Task<Void, Never>?
    private var voiceFilter: VoiceFilterEngine?
    /// Independent of `modelState`: a failed or still-loading voice filter
    /// must never block dictation. It only ever gates whether filtering is
    /// applied — see `applyVoiceFilterIfNeeded`.
    public private(set) var voiceFilterState: SpeechModelLoadState = .idle
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
    public func start(requestMicrophonePermission: Bool = true) async {
        // Ask for the microphone here, at launch, while nothing is happening.
        // The System Settings Microphone pane has no "+" button, so the system
        // prompt is the *only* way this grant can ever be given — and if we
        // wait until the first hotkey press to ask, the prompt steals focus
        // mid-sentence and that dictation is lost regardless of the answer.
        if requestMicrophonePermission,
           AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await Permission.microphone.request()
        }

        do {
            try hotkeys.start()
        } catch {
            phase = .error(error.localizedDescription)
        }
        await reloadModel()
        await reloadVoiceFilterIfNeeded()
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
        stopLivePreview()
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

    /// Refreshes Cloud credentials in memory to match `settings.cleanupProvider`
    /// without touching the speech engine — picking Plainsay as the Polishing
    /// provider doesn't warrant tearing down and reloading an unrelated
    /// on-device model, the way changing the transcription source does.
    public func refreshCloudCleanupIfNeeded() async {
        await refreshCloudCredentialsIfNeeded()
    }

    /// Loads or releases the voice filter to match `settings.voiceFilterEnabled`.
    /// Safe to call repeatedly — a no-op once the current state already
    /// matches the setting.
    public func reloadVoiceFilterIfNeeded() async {
        guard settings.voiceFilterEnabled else {
            let filter = voiceFilter
            voiceFilter = nil
            voiceFilterState = .idle
            await filter?.shutdown()
            return
        }
        guard voiceFilter == nil else { return }

        let filter = VoiceFilterEngine(onStateChange: { [weak self] state in
            Task { @MainActor [weak self] in self?.voiceFilterState = state }
        })
        voiceFilter = filter
        do {
            try await filter.prepare()
        } catch {
            Log.model.error("voice filter failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Filters `samples` down to the enrolled voice when the feature is on
    /// and actually ready. Fails open on any problem — an unloaded filter, a
    /// missing enrollment, or a diarization error all just mean "transcribe
    /// what was recorded," the same as if filtering were off.
    private func applyVoiceFilterIfNeeded(_ samples: [Float]) async -> [Float] {
        guard settings.voiceFilterEnabled,
              let embedding = settings.voiceEmbedding,
              let voiceFilter,
              await voiceFilter.isReady
        else { return samples }

        do {
            return try await voiceFilter.filtered(samples: samples, matching: embedding)
        } catch {
            Log.pipeline.error("voice filter failed, using unfiltered audio: \(error.localizedDescription, privacy: .public)")
            return samples
        }
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

        // Source changes from Settings or a reopened setup assistant do not go
        // through `start()`. Refresh here so switching to an active Cloud
        // subscription never builds the engine with stale/nil credentials.
        await refreshCloudCredentialsIfNeeded()
        guard !Task.isCancelled, generation == modelLoadGeneration else { return }

        await loadModel(generation: generation)
    }

    /// Confirms the hosted plan is actually active and puts the session token
    /// where `CloudTranscriptionEngine` and `CloudCleanupService` can find it.
    ///
    /// Only called when something actually needs it — Cloud transcription, or
    /// Plainsay picked as the Polishing provider — so someone using on-device
    /// speech with a BYOK editing provider never causes a network call to the
    /// subscription service.
    private func refreshCloudCredentialsIfNeeded() async {
        let needsCloud = settings.transcriptionSource == .cloud || settings.cleanupProvider == .plainsay
        guard needsCloud, cloud.isSignedIn else {
            ProviderFactory.cloudSessionToken = nil
            return
        }

        do {
            let account = try await cloud.refreshAccount()
            guard account.isActive else {
                ProviderFactory.cloudSessionToken = nil
                Log.model.info("Plainsay Cloud subscription is \(account.status, privacy: .public)")
                return
            }
            ProviderFactory.cloudSessionToken = cloud.sessionToken
            Log.model.info("Plainsay Cloud session token loaded into memory")
        } catch {
            ProviderFactory.cloudSessionToken = nil
            Log.model.error("Plainsay Cloud unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadModel(generation: UInt64) async {
        let onState: @Sendable (SpeechModelLoadState) -> Void = { [weak self] state in
            Task { @MainActor in
                guard let self, self.modelLoadGeneration == generation else { return }
                self.applyReportedModelState(state)
            }
        }
        // Tests inject `makeEngine`; production goes through the factory, which
        // is the only thing that knows about remote providers.
        let engine = usesInjectedEngine
            ? makeEngine(settings.model, settings.primaryLanguage, onState)
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
            applyModelState(.ready)
        } catch {
            guard generation == modelLoadGeneration else {
                self.engine = nil
                await engine.shutdown()
                return
            }
            applyModelState(.failed(error.localizedDescription))
        }
    }

    /// Keeps the model-status HUD in sync with the load that prompted it. A
    /// successful load gets a brief confirmation; a failed load expands into
    /// the normal error treatment rather than leaving an endless progress bar.
    private func applyModelState(_ state: SpeechModelLoadState) {
        modelState = state
        guard phase == .modelLoading else { return }

        switch state {
        case .ready:
            scheduleReset(after: .seconds(1))
        case .failed(let message):
            flashError(
                Localization.coreFormat(
                    "coordinator.modelStatus.failed", fallback: "Speech model failed to load: %@", message
                )
            )
        case .idle, .downloading, .loading:
            break
        }
    }

    /// Progress callbacks cross actors through an unstructured MainActor task.
    /// A callback queued just before `prepare()` returns can therefore arrive
    /// after the coordinator has authoritatively marked the same load ready or
    /// failed. Terminal completion is sticky until the next generation resets
    /// the state to idle.
    private func applyReportedModelState(_ state: SpeechModelLoadState) {
        switch modelState {
        case .ready, .failed:
            return
        case .idle, .downloading, .loading:
            applyModelState(state)
        }
    }

    /// What to say when someone presses the hotkey before the model is up.
    private var modelStatusMessage: String {
        switch modelState {
        case .idle:
            Localization.coreString("coordinator.modelStatus.starting", fallback: "Starting the speech model…")
        case .downloading:
            Localization.coreFormat(
                "coordinator.modelStatus.downloading",
                fallback: "Downloading the speech model (%@). This happens once.",
                settings.model.approximateSize
            )
        case .loading:
            // The Neural Engine compile runs once per model and takes minutes.
            // Quitting restarts it from scratch, so say not to.
            Localization.coreString(
                "coordinator.modelStatus.preparing",
                fallback: "Preparing the speech model for the Neural Engine. This takes a few minutes the first time — leave Plainsay running."
            )
        case .ready:
            Localization.coreString("coordinator.modelStatus.ready", fallback: "Ready")
        case .failed(let message):
            Localization.coreFormat(
                "coordinator.modelStatus.failed", fallback: "Speech model failed to load: %@", message
            )
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

        switch modelState {
        case .ready:
            break
        case .idle, .downloading, .loading:
            // Loading is an expected first-run state, not an error. Leave this
            // phase visible until the engine becomes ready (or fails) so the
            // HUD can show the same live progress as Settings.
            phase = .modelLoading
            machine.reset()
            return
        case .failed:
            flashError(modelStatusMessage)
            machine.reset()
            return
        }

        // Never trigger a system prompt from the hotkey: it steals focus and
        // guarantees that the sentence being spoken is lost. The setup and
        // Settings permission buttons own that interaction.
        guard AudioRecorder.microphoneAuthorized() else {
            flashError(
                Localization.coreString("coordinator.needsMicrophone", fallback: "Plainsay needs microphone access")
            )
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
        startLivePreview()
    }

    private func endRecording() {
        stopMetering()
        stopLivePreview()
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
            flashError(Localization.coreString("coordinator.modelNotLoaded", fallback: "Speech model not loaded"))
            return
        }

        phase = .transcribing
        let prompt = settings.dictionary.asrPrompt()
        // Filtering happens on the full recording, before transcription and
        // before anything leaves this Mac for a remote/Cloud engine — a
        // second voice in the room is removed here, not redacted afterward.
        let filteredSamples = await applyVoiceFilterIfNeeded(samples)

        let started = Date()
        var transcript: String
        do {
            transcript = try await engine.transcribe(samples: filteredSamples, prompt: prompt)
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

        // Local, deterministic, and unconditional: engines that don't accept
        // decoder hints (Parakeet) otherwise have no path to vocabulary
        // corrections at all unless editing happens to catch them too.
        transcript = settings.dictionary.applyCorrections(to: transcript)

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

        // Polishing is a remote LLM's output, not a fixed local transform —
        // unlike the ASR engines' own normalizeTranscript pass, nothing
        // guarantees it never contains a stray control byte. Sanitized once
        // here so both the auto-paste below and a later manual copy from
        // history see the same safe text.
        finalText = sanitizeForInsertion(finalText)
        lastTranscript = finalText

        // Written down *before* the paste is attempted. Insertion is the one
        // step we cannot verify, so the history has to survive its failure.
        record(
            text: finalText,
            raw: transcript,
            outcome: usedRaw ? .insertedWithoutCleanup : .inserted,
            duration: duration
        )

        let outcome = await insert(finalText)

        switch outcome {
        case .inserted:
            phase = usedRaw ? .insertedRaw : .idle
            scheduleReset()
        case .noFocusedElement:
            // Longer than the normal reset: this is the one outcome that
            // needs the user to actually read and act on it before it fades.
            phase = .savedToClipboard
            scheduleReset(after: .seconds(5))
        }
        playSound("Pop")
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

    private func insert(_ text: String) async -> TextInsertionOutcome {
        if let targetApp, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != targetApp.bundleIdentifier {
            // The user switched apps mid-dictation. Paste where they are now —
            // stealing focus back would be more surprising than a stray paste.
            NSLog("[Plainsay] frontmost app changed during dictation; inserting into current app")
        }
        let outcome = await inserter.insert(text, keepOnClipboard: settings.keepOnClipboard)
        targetApp = nil
        return outcome
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

    /// Re-transcribes the growing recording every couple of seconds so the
    /// HUD can show a rough live readout. Deliberately not streaming ASR
    /// itself: each pass is a fresh full-buffer call through the same engine
    /// `stop()` will use, so a pass still in flight when recording stops
    /// simply finishes first — the engine actor serializes both, adding at
    /// most one preview pass's worth of latency to the real transcription.
    private func startLivePreview() {
        livePreviewText = ""
        guard settings.livePreviewEnabled, settings.transcriptionSource == .onDevice else { return }
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.previewInterval)
                guard !Task.isCancelled, let self,
                      self.phase == .recording, self.recorder.isRecording,
                      let engine = self.engine
                else { return }

                let samples = self.recorder.peek()
                guard Double(samples.count) / whisperSampleRate >= Self.minimumDuration else { continue }

                let prompt = self.settings.dictionary.asrPrompt()
                let text = (try? await engine.transcribe(samples: samples, prompt: prompt)) ?? ""
                guard !Task.isCancelled, self.phase == .recording, !text.isEmpty else { continue }
                self.livePreviewText = text
            }
        }
    }

    private func stopLivePreview() {
        previewTask?.cancel()
        previewTask = nil
        livePreviewText = ""
    }

    private func flashError(_ message: String) {
        stopMetering()
        stopLivePreview()
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
