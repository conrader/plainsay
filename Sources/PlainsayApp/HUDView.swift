import SwiftUI
import PlainsayCore

/// Everything the HUD draws, as a plain value.
///
/// The HUD takes this rather than the coordinator so it can be rendered — and
/// looked at — without a microphone, a model, or any permissions.
struct HUDState: Equatable {
    var phase: DictationCoordinator.Phase = .idle
    var modelState: SpeechModelLoadState = .idle
    var modelLoadTiming: SpeechModelLoadTiming?
    var levelHistory: [Float] = []
    var elapsed: TimeInterval = 0
    var livePreviewText: String = ""
    var recordingStyle: HotkeyRecordingStyle?

    init(
        phase: DictationCoordinator.Phase = .idle,
        modelState: SpeechModelLoadState = .idle,
        modelLoadTiming: SpeechModelLoadTiming? = nil,
        levelHistory: [Float] = [],
        elapsed: TimeInterval = 0,
        livePreviewText: String = "",
        recordingStyle: HotkeyRecordingStyle? = nil
    ) {
        self.phase = phase
        self.modelState = modelState
        self.modelLoadTiming = modelLoadTiming
        self.levelHistory = levelHistory
        self.elapsed = elapsed
        self.livePreviewText = livePreviewText
        self.recordingStyle = recordingStyle
    }

    @MainActor
    init(_ coordinator: DictationCoordinator) {
        phase = coordinator.phase
        modelState = coordinator.modelState
        modelLoadTiming = coordinator.modelLoadTiming
        levelHistory = coordinator.levelHistory
        elapsed = coordinator.elapsed
        livePreviewText = coordinator.livePreviewText
        recordingStyle = coordinator.recordingStyle
    }
}

/// The floating readout shown while a dictation is in flight.
struct HUDView: View {
    let state: HUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state.phase == .modelLoading {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    hudBody(now: context.date)
                }
            } else {
                hudBody(now: Date())
            }
        }
    }

    private func hudBody(now: Date) -> some View {
        Group {
            if state.phase == .modelLoading {
                HUDModelProgressView(state: state.modelState, timing: state.modelLoadTiming, now: now)
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

                    if state.phase == .recording {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(label)
                                .font(.hudLabel)
                                .instrumentTracking()
                                .foregroundStyle(labelColor)
                            Text(recordingHint)
                                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Palette.slate)
                                .fixedSize()
                        }
                    } else {
                        Text(label)
                            .font(.hudLabel)
                            .instrumentTracking()
                            .foregroundStyle(labelColor)
                            .fixedSize()
                    }

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
        .accessibilityLabel(accessibilityLabel(now: now))
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
        state.phase == .transcribing || state.phase == .cleaning
    }

    private var label: String {
        switch state.phase {
        case .recording: Localization.appString("hud.label.listening", fallback: "LISTENING")
        case .transcribing: Localization.appString("hud.label.transcribing", fallback: "TRANSCRIBING")
        case .cleaning: Localization.appString("hud.label.polishing", fallback: "POLISHING")
        case .modelLoading: Localization.appString("hud.label.preparingModel", fallback: "PREPARING MODEL")
        case .insertedRaw: Localization.appString("hud.label.insertedRaw", fallback: "INSERTED · RAW")
        case .savedToClipboard: Localization.appString("hud.label.savedToClipboard", fallback: "SAVED TO CLIPBOARD")
        case .cancelled: Localization.appString("hud.label.cancelled", fallback: "CANCELLED")
        case .error: Localization.appString("hud.label.error", fallback: "ERROR")
        case .idle: ""
        }
    }

    private var labelColor: Color {
        switch state.phase {
        case .recording: Palette.bone
        case .insertedRaw, .error: Palette.ember
        case .savedToClipboard: Palette.signal
        case .cancelled: Palette.slate
        default: Palette.slate
        }
    }

    private var borderColor: Color {
        switch state.phase {
        case .error, .insertedRaw: Palette.ember.opacity(0.45)
        case .savedToClipboard: Palette.signal.opacity(0.45)
        default: Palette.veil
        }
    }

    private var timecode: String {
        let total = Int(state.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var recordingHint: String {
        switch state.recordingStyle {
        case .releaseToFinish:
            Localization.appString("hud.hint.release", fallback: "RELEASE · ESC CANCELS")
        case .tapToFinish:
            Localization.appString("hud.hint.tapAgain", fallback: "TAP AGAIN · ESC CANCELS")
        case nil:
            Localization.appString("hud.hint.escape", fallback: "ESC CANCELS")
        }
    }

    private func accessibilityLabel(now: Date) -> String {
        switch state.phase {
        case .recording:
            recordingAccessibilityLabel
        case .transcribing: Localization.appString("hud.a11y.transcribing", fallback: "Transcribing")
        case .cleaning: Localization.appString("hud.a11y.polishing", fallback: "Polishing transcript")
        case .modelLoading: modelAccessibilityLabel(now: now)
        case .insertedRaw:
            Localization.appString("hud.a11y.insertedRaw", fallback: "Inserted raw transcript, cleanup unavailable")
        case .savedToClipboard:
            Localization.appString(
                "hud.a11y.savedToClipboard",
                fallback: "Nothing was focused to paste into. Dictation saved to the clipboard — press Command V to paste it."
            )
        case .cancelled:
            Localization.appString("hud.a11y.cancelled", fallback: "Dictation cancelled")
        case .error(let message):
            Localization.appFormat("hud.a11y.error", fallback: "Error: %@", message)
        case .idle: Localization.appString("hud.a11y.idle", fallback: "Idle")
        }
    }

    private var recordingAccessibilityLabel: String {
        switch state.recordingStyle {
        case .releaseToFinish:
            Localization.appFormat(
                "hud.a11y.listeningRelease",
                fallback: "Listening, %d seconds. Release to finish; Escape cancels.",
                Int(state.elapsed)
            )
        case .tapToFinish:
            Localization.appFormat(
                "hud.a11y.listeningTap",
                fallback: "Listening, %d seconds. Tap again to finish; Escape cancels.",
                Int(state.elapsed)
            )
        case nil:
            Localization.appFormat(
                "hud.a11y.listeningCancel",
                fallback: "Listening, %d seconds. Escape cancels.",
                Int(state.elapsed)
            )
        }
    }

    private func modelAccessibilityLabel(now: Date) -> String {
        let base = switch state.modelState {
        case .idle:
            Localization.appString("hud.a11y.model.starting", fallback: "Starting speech model")
        case .downloading:
            Localization.appString("modelStatus.a11y.downloading", fallback: "Downloading speech model")
        case .loading:
            Localization.appString("hud.a11y.model.preparing", fallback: "Preparing speech model")
        case .ready:
            Localization.appString("hud.a11y.model.ready", fallback: "Speech model ready")
        case .failed(let message):
            Localization.appFormat("hud.a11y.model.failed", fallback: "Speech model failed to load: %@", message)
        }

        let presentation = ModelLoadPresentation(
            state: state.modelState,
            timing: state.modelLoadTiming,
            now: now
        )
        return [base, presentation.accessibilityProgress, presentation.attentionMessage]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

}

/// Compact progress treatment for the hotkey HUD. The larger Settings and
/// Setup Assistant use `ModelLoadStatusView`; this keeps the same wording and
/// progress semantics within the HUD's fixed one-line footprint.
private struct HUDModelProgressView: View {
    let state: SpeechModelLoadState
    let timing: SpeechModelLoadTiming?
    let now: Date

    var body: some View {
        content(presentation: ModelLoadPresentation(state: state, timing: timing, now: now))
    }

    private func content(presentation: ModelLoadPresentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(label(presentation: presentation))
                    .font(.hudLabel)
                    .instrumentTracking()
                    .foregroundStyle(labelColor(presentation: presentation))
                Spacer(minLength: 8)
                if let summary = presentation.progressSummary {
                    Text(summary)
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

    private func label(presentation: ModelLoadPresentation) -> String {
        switch presentation.attention {
        case .downloadStalled:
            return Localization.appString("hud.progress.downloadStalled", fallback: "NO DOWNLOAD PROGRESS")
        case .downloadActionRequired:
            return Localization.appString("hud.progress.mayBeStuck", fallback: "MODEL MAY BE STUCK")
        case .takingLonger, .firstPreparation:
            return Localization.appString("hud.progress.stillPreparing", fallback: "STILL PREPARING")
        case .actionRequired:
            return Localization.appString("hud.progress.mayBeStuck", fallback: "MODEL MAY BE STUCK")
        case nil:
            break
        }

        return switch state {
        case .idle: Localization.appString("hud.progress.starting", fallback: "STARTING MODEL")
        case .downloading: Localization.appString("hud.progress.downloading", fallback: "DOWNLOADING MODEL")
        case .loading: Localization.appString("hud.progress.preparing", fallback: "PREPARING MODEL")
        case .ready: Localization.appString("hud.progress.ready", fallback: "MODEL READY")
        case .failed: Localization.appString("hud.progress.error", fallback: "MODEL ERROR")
        }
    }

    private func labelColor(presentation: ModelLoadPresentation) -> Color {
        if presentation.attention == .downloadStalled
            || presentation.attention == .downloadActionRequired
            || presentation.attention == .actionRequired
        {
            return Palette.ember
        }
        return switch state {
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
