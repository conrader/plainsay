import SwiftUI
import PlainsayCore

/// Everything the HUD draws, as a plain value.
///
/// The HUD takes this rather than the coordinator so it can be rendered — and
/// looked at — without a microphone, a model, or any permissions.
struct HUDState: Equatable {
    var phase: DictationCoordinator.Phase = .idle
    var modelState: SpeechModelLoadState = .idle
    var levelHistory: [Float] = []
    var elapsed: TimeInterval = 0
    var livePreviewText: String = ""

    init(
        phase: DictationCoordinator.Phase = .idle,
        modelState: SpeechModelLoadState = .idle,
        levelHistory: [Float] = [],
        elapsed: TimeInterval = 0,
        livePreviewText: String = ""
    ) {
        self.phase = phase
        self.modelState = modelState
        self.levelHistory = levelHistory
        self.elapsed = elapsed
        self.livePreviewText = livePreviewText
    }

    @MainActor
    init(_ coordinator: DictationCoordinator) {
        phase = coordinator.phase
        modelState = coordinator.modelState
        levelHistory = coordinator.levelHistory
        elapsed = coordinator.elapsed
        livePreviewText = coordinator.livePreviewText
    }
}

/// The floating readout shown while a dictation is in flight.
struct HUDView: View {
    let state: HUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state.phase == .modelLoading {
                HUDModelProgressView(state: state.modelState)
            } else {
                HStack(spacing: 12) {
                    WaveformRibbon(
                        levels: state.levelHistory,
                        isLive: state.phase == .recording,
                        capacity: DictationCoordinator.levelHistoryLength,
                        tint: labelColor
                    )
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)

                    Text(label)
                        .font(.hudLabel)
                        .instrumentTracking()
                        .foregroundStyle(labelColor)
                        .fixedSize()

                    if state.phase == .recording {
                        Text(timecode)
                            .font(.hudTimer)
                            .foregroundStyle(Palette.slate)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Metrics.hudWidth, height: Metrics.hudHeight)
        .background(hudBackground)
        .overlay(alignment: .bottom) {
            if isWorking {
                ProgressSweep(tint: Palette.signal)
                    .padding(.horizontal, 1)
                    .padding(.bottom, 1)
            }
        }
        .clipShape(.rect(cornerRadius: Metrics.hudCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.hudCornerRadius)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var hudBackground: some View {
        // Ink over the system's blur: the HUD sits on unknown wallpaper and
        // needs its own ground to stay legible, but shouldn't look pasted on.
        ZStack {
            VisualEffectBackground()
            Palette.ink.opacity(0.88)
        }
    }

    private var isWorking: Bool {
        switch state.phase {
        case .recordingLimitReached, .transcribing, .cleaning: true
        default: false
        }
    }

    private var label: String {
        switch state.phase {
        case .recording: Localization.appString("hud.label.listening", fallback: "LISTENING")
        case .recordingLimitReached:
            Localization.appString("hud.label.recordingLimitReached", fallback: "10-MINUTE LIMIT")
        case .transcribing: Localization.appString("hud.label.transcribing", fallback: "TRANSCRIBING")
        case .cleaning: Localization.appString("hud.label.polishing", fallback: "POLISHING")
        case .modelLoading: Localization.appString("hud.label.preparingModel", fallback: "PREPARING MODEL")
        case .insertedRaw: Localization.appString("hud.label.insertedRaw", fallback: "INSERTED · RAW")
        case .savedToClipboard: Localization.appString("hud.label.savedToClipboard", fallback: "SAVED TO CLIPBOARD")
        case .error: Localization.appString("hud.label.error", fallback: "ERROR")
        case .idle: ""
        }
    }

    private var labelColor: Color {
        switch state.phase {
        case .recording: Palette.bone
        case .recordingLimitReached: Palette.signal
        case .insertedRaw, .error: Palette.ember
        case .savedToClipboard: Palette.signal
        default: Palette.slate
        }
    }

    private var borderColor: Color {
        switch state.phase {
        case .error, .insertedRaw: Palette.ember.opacity(0.45)
        case .recordingLimitReached, .savedToClipboard: Palette.signal.opacity(0.45)
        default: Palette.veil
        }
    }

    private var timecode: String {
        let total = Int(state.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var accessibilityLabel: String {
        switch state.phase {
        case .recording:
            Localization.appFormat("hud.a11y.listening", fallback: "Listening, %d seconds", Int(state.elapsed))
        case .recordingLimitReached:
            Localization.appString(
                "hud.a11y.recordingLimitReached",
                fallback: "Ten-minute recording limit reached. Recording stopped automatically; processing the captured audio."
            )
        case .transcribing: Localization.appString("hud.a11y.transcribing", fallback: "Transcribing")
        case .cleaning: Localization.appString("hud.a11y.polishing", fallback: "Polishing transcript")
        case .modelLoading: modelAccessibilityLabel
        case .insertedRaw:
            Localization.appString("hud.a11y.insertedRaw", fallback: "Inserted raw transcript, cleanup unavailable")
        case .savedToClipboard:
            Localization.appString(
                "hud.a11y.savedToClipboard",
                fallback: "Nothing was focused to paste into. Dictation saved to the clipboard — press Command V to paste it."
            )
        case .error(let message):
            Localization.appFormat("hud.a11y.error", fallback: "Error: %@", message)
        case .idle: Localization.appString("hud.a11y.idle", fallback: "Idle")
        }
    }

    private var modelAccessibilityLabel: String {
        switch state.modelState {
        case .idle:
            Localization.appString("hud.a11y.model.starting", fallback: "Starting speech model")
        case .downloading(let progress):
            Localization.appFormat(
                "hud.a11y.model.downloading", fallback: "Downloading speech model, %d percent", percentage(progress)
            )
        case .loading(let progress):
            if let progress {
                Localization.appFormat(
                    "hud.a11y.model.preparingWithProgress", fallback: "Preparing speech model, %d percent",
                    percentage(progress)
                )
            } else {
                Localization.appString("hud.a11y.model.preparing", fallback: "Preparing speech model")
            }
        case .ready:
            Localization.appString("hud.a11y.model.ready", fallback: "Speech model ready")
        case .failed(let message):
            Localization.appFormat("hud.a11y.model.failed", fallback: "Speech model failed to load: %@", message)
        }
    }

    private func percentage(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 100).rounded())
    }
}

/// Compact progress treatment for the hotkey HUD. The larger Settings and
/// Setup Assistant use `ModelLoadStatusView`; this keeps the same wording and
/// progress semantics within the HUD's fixed one-line footprint.
private struct HUDModelProgressView: View {
    let state: SpeechModelLoadState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.hudLabel)
                    .instrumentTracking()
                    .foregroundStyle(labelColor)
                Spacer(minLength: 8)
                if let percentage {
                    Text(Localization.appFormat("hud.progress.percentage", fallback: "%d%%", percentage))
                        .font(.hudTimer)
                        .foregroundStyle(Palette.slate)
                        .monospacedDigit()
                }
            }

            progressView
                .progressViewStyle(.linear)
                .tint(progressTint)
        }
    }

    @ViewBuilder
    private var progressView: some View {
        switch state {
        case .downloading(let progress):
            ProgressView(value: normalized(progress))
        case .loading(let progress):
            if let progress {
                ProgressView(value: normalized(progress))
            } else {
                ProgressView()
            }
        case .ready:
            ProgressView(value: 1)
        case .idle:
            ProgressView()
        case .failed:
            ProgressView(value: 0)
        }
    }

    private var label: String {
        switch state {
        case .idle: Localization.appString("hud.progress.starting", fallback: "STARTING MODEL")
        case .downloading: Localization.appString("hud.progress.downloading", fallback: "DOWNLOADING MODEL")
        case .loading: Localization.appString("hud.progress.preparing", fallback: "PREPARING MODEL")
        case .ready: Localization.appString("hud.progress.ready", fallback: "MODEL READY")
        case .failed: Localization.appString("hud.progress.error", fallback: "MODEL ERROR")
        }
    }

    private var labelColor: Color {
        switch state {
        case .ready: Palette.signal
        case .failed: Palette.ember
        default: Palette.bone
        }
    }

    private var progressTint: Color {
        switch state {
        case .failed: Palette.ember
        default: Palette.signal
        }
    }

    private var percentage: Int? {
        switch state {
        case .downloading(let progress):
            Int((normalized(progress) * 100).rounded())
        case .loading(let progress):
            progress.map { Int((normalized($0) * 100).rounded()) }
        case .ready:
            100
        case .idle, .failed:
            nil
        }
    }

    private func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Explanatory text too long for the readout row gets its own line below the
/// HUD rather than truncating in it — failures and the clipboard-fallback
/// notice both use this, distinguished only by tint.
struct HUDErrorView: View {
    let message: String
    var tint: Color = Palette.ember
    /// `.head` for a live preview, so the words just spoken stay visible as
    /// the sentence grows past two lines instead of scrolling out of view.
    var truncationMode: Text.TruncationMode = .tail

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Palette.bone.opacity(0.9))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(truncationMode)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: Metrics.hudWidth)
            .background {
                ZStack {
                    VisualEffectBackground()
                    Palette.ink.opacity(0.88)
                }
            }
            .clipShape(.rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The HUD's full stack: readout, plus an error line when there is one.
struct HUDContainer: View {
    let state: HUDState

    var body: some View {
        VStack(spacing: 8) {
            HUDView(state: state)
            if case .error(let message) = state.phase {
                HUDErrorView(message: message)
            }
            if case .savedToClipboard = state.phase {
                HUDErrorView(
                    message: Localization.appString(
                        "hud.error.clipboard",
                        fallback: "Nothing was focused to paste into — your dictation is on the clipboard. Press ⌘V to paste it."
                    ),
                    tint: Palette.signal
                )
            }
            if case .recordingLimitReached = state.phase {
                HUDErrorView(
                    message: Localization.appString(
                        "hud.notice.recordingLimitReached",
                        fallback: "Recording stopped automatically. The captured audio is being processed."
                    ),
                    tint: Palette.signal
                )
            }
            if state.phase == .recording, !state.livePreviewText.isEmpty {
                HUDErrorView(message: state.livePreviewText, tint: Palette.slate, truncationMode: .head)
            }
        }
        .padding(24)
    }
}

/// Bridges the live coordinator to the HUD's plain state. Reading the
/// coordinator's properties here is what makes SwiftUI redraw as they change.
struct HUDHost: View {
    let coordinator: DictationCoordinator

    var body: some View {
        HUDContainer(state: HUDState(coordinator))
    }
}
