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

    init(
        phase: DictationCoordinator.Phase = .idle,
        modelState: SpeechModelLoadState = .idle,
        levelHistory: [Float] = [],
        elapsed: TimeInterval = 0
    ) {
        self.phase = phase
        self.modelState = modelState
        self.levelHistory = levelHistory
        self.elapsed = elapsed
    }

    @MainActor
    init(_ coordinator: DictationCoordinator) {
        phase = coordinator.phase
        modelState = coordinator.modelState
        levelHistory = coordinator.levelHistory
        elapsed = coordinator.elapsed
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
        state.phase == .transcribing || state.phase == .cleaning
    }

    private var label: String {
        switch state.phase {
        case .recording: "LISTENING"
        case .transcribing: "TRANSCRIBING"
        case .cleaning: "POLISHING"
        case .modelLoading: "PREPARING MODEL"
        case .insertedRaw: "INSERTED · RAW"
        case .savedToClipboard: "SAVED TO CLIPBOARD"
        case .error: "ERROR"
        case .idle: ""
        }
    }

    private var labelColor: Color {
        switch state.phase {
        case .recording: Palette.bone
        case .insertedRaw, .error: Palette.ember
        case .savedToClipboard: Palette.signal
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

    private var accessibilityLabel: String {
        switch state.phase {
        case .recording: "Listening, \(Int(state.elapsed)) seconds"
        case .transcribing: "Transcribing"
        case .cleaning: "Polishing transcript"
        case .modelLoading: modelAccessibilityLabel
        case .insertedRaw: "Inserted raw transcript, cleanup unavailable"
        case .savedToClipboard: "Nothing was focused to paste into. Dictation saved to the clipboard — press Command V to paste it."
        case .error(let message): "Error: \(message)"
        case .idle: "Idle"
        }
    }

    private var modelAccessibilityLabel: String {
        switch state.modelState {
        case .idle:
            "Starting speech model"
        case .downloading(let progress):
            "Downloading speech model, \(percentage(progress)) percent"
        case .loading(let progress):
            if let progress {
                "Preparing speech model, \(percentage(progress)) percent"
            } else {
                "Preparing speech model"
            }
        case .ready:
            "Speech model ready"
        case .failed(let message):
            "Speech model failed to load: \(message)"
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
                    Text("\(percentage)%")
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
        case .idle: "STARTING MODEL"
        case .downloading: "DOWNLOADING MODEL"
        case .loading: "PREPARING MODEL"
        case .ready: "MODEL READY"
        case .failed: "MODEL ERROR"
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

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Palette.bone.opacity(0.9))
            .multilineTextAlignment(.center)
            .lineLimit(2)
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
                    message: "Nothing was focused to paste into — your dictation is on the clipboard. Press ⌘V to paste it.",
                    tint: Palette.signal
                )
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
