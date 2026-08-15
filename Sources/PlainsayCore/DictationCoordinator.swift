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
    public private(set) var modelState: WhisperKitEngine.LoadState = .idle
    public private(set) var lastTranscript: String?

    /// Every dictation, written down before insertion is attempted.
    public let history: TranscriptHistory

    private let settings: PlainsaySettings
    private let recorder: any AudioRecording
    private let inserter: any TextInserting
    private var engine: (any TranscriptionEngine)?
    private let makeEngine: @MainActor (WhisperModel, String?, @escaping @Sendable (WhisperKitEngine.LoadState) -> Void) -> any TranscriptionEngine
    private let makeCleaner: @MainActor (PlainsaySettings) -> any TextCleaning

    private let hotkeys: HotkeyMonitor
    private var machine: HotkeyStateMachine
    private var meterTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?

    public init(
        settings: PlainsaySettings = .shared,
        history: TranscriptHistory = TranscriptHistory(),
        recorder: any AudioRecording = AudioRecorder(),
        inserter: any TextInserting = PasteboardTextInserter(),
        makeEngine: @escaping @MainActor (WhisperModel, String?, @escaping @Sendable (WhisperKitEngine.LoadState) -> Void) -> any TranscriptionEngine = { model, language, onState in
            WhisperKitEngine(model: model, language: language, onStateChange: onState)
        },
        makeCleaner: @escaping @MainActor (PlainsaySettings) -> any TextCleaning = { settings in
            guard settings.cleanupEnabled, settings.hasGeminiKey else { return NoCleanup() }
            return GeminiCleanupService(apiKey: settings.geminiAPIKey)
        }
    ) {
        self.settings = settings
        self.history = history
        self.recorder = recorder
        self.inserter = inserter
        self.makeEngine = makeEngine
        self.makeCleaner = makeCleaner
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

        do {
            try hotkeys.start()
        } catch {
            phase = .error(error.localizedDescription)
        }
        await loadModel()
    }

    public func stop() {
        hotkeys.stop()
        meterTask?.cancel()
        recorder.cancel()
        machine.reset()
        phase = .idle
    }

    /// Applies changed settings without a relaunch.
    public func settingsChanged() {
        hotkeys.binding = settings.binding
        machine.mode = settings.hotkeyMode
    }

    public func reloadModel() async {
        engine = nil
        await loadModel()
    }

    private func loadModel() async {
        let engine = makeEngine(settings.model, settings.language) { [weak self] state in
            Task { @MainActor in self?.modelState = state }
        }
        self.engine = engine
        do {
            try await engine.prepare()
            // Don't depend on the engine having reported readiness itself —
            // a successful `prepare()` is the definition of ready.
            modelState = .ready
        } catch {
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
            return
        }

        Task { await process(samples) }
    }

    // MARK: - Pipeline

    private func process(_ samples: [Float]) async {
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
