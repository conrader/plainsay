import SwiftUI
import PlainsayCore

/// Everything the HUD draws, as a plain value.
///
/// The HUD takes this rather than the coordinator so it can be rendered — and
/// looked at — without a microphone, a model, or any permissions.
struct HUDState: Equatable {
    var phase: DictationCoordinator.Phase = .idle
    var levelHistory: [Float] = []
    var elapsed: TimeInterval = 0

    init(phase: DictationCoordinator.Phase = .idle, levelHistory: [Float] = [], elapsed: TimeInterval = 0) {
        self.phase = phase
        self.levelHistory = levelHistory
        self.elapsed = elapsed
    }

    @MainActor
    init(_ coordinator: DictationCoordinator) {
        phase = coordinator.phase
        levelHistory = coordinator.levelHistory
        elapsed = coordinator.elapsed
    }
}

/// The floating readout shown while a dictation is in flight.
struct HUDView: View {
    let state: HUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
        case .insertedRaw: "INSERTED · RAW"
        case .error: "ERROR"
        case .idle: ""
        }
    }

    private var labelColor: Color {
        switch state.phase {
        case .recording: Palette.bone
        case .insertedRaw, .error: Palette.ember
        default: Palette.slate
        }
    }

    private var borderColor: Color {
        switch state.phase {
        case .error, .insertedRaw: Palette.ember.opacity(0.45)
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
        case .insertedRaw: "Inserted raw transcript, cleanup unavailable"
        case .error(let message): "Error: \(message)"
        case .idle: "Idle"
        }
    }
}

/// Error text is too long for the readout row, so failures get their own line
/// below the HUD rather than truncating in it.
struct HUDErrorView: View {
    let message: String

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
                    .strokeBorder(Palette.ember.opacity(0.35), lineWidth: 1)
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
