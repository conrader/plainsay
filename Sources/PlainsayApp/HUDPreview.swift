import AppKit
import SwiftUI
import PlainsayCore

/// Renders every HUD state at once, over a mid-grey ground, so the design can
/// be reviewed without a microphone or any permissions.
///
/// Launch with `WSPR_HUD_PREVIEW=1 open build/Plainsay.app`.
struct HUDPreview: View {
    /// A plausible utterance: a couple of loud syllables, a pause for breath,
    /// then a trailing-off phrase. A sine wave would flatter the design.
    private static let sampleLevels: [Float] = {
        (0..<110).map { i in
            let t = Double(i) / 110
            let envelope = sin(t * .pi * 3.1) * 0.5 + 0.5
            let syllable = abs(sin(t * .pi * 22))
            let breath = (t > 0.44 && t < 0.54) ? 0.05 : 1.0
            return Float(min(1, envelope * syllable * breath * 1.25))
        }
    }()

    private static let states: [(String, HUDState)] = [
        ("Recording", HUDState(phase: .recording, levelHistory: sampleLevels, elapsed: 7)),
        ("Just started", HUDState(phase: .recording, levelHistory: Array(sampleLevels.prefix(14)), elapsed: 0)),
        ("Transcribing", HUDState(phase: .transcribing, levelHistory: sampleLevels)),
        ("Polishing", HUDState(phase: .cleaning, levelHistory: sampleLevels)),
        ("Downloading model", HUDState(
            phase: .modelLoading,
            modelState: .downloading(progress: 0.42)
        )),
        ("Preparing model", HUDState(
            phase: .modelLoading,
            modelState: .loading(progress: nil)
        )),
        ("Cleanup unavailable", HUDState(phase: .insertedRaw, levelHistory: sampleLevels)),
        ("Error", HUDState(
            phase: .error("Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone."),
            levelHistory: []
        )),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(Self.states, id: \.0) { name, state in
                    VStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                        HUDContainer(state: state)
                    }
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(
            // Mid-grey rather than black: the HUD sits on real wallpaper, and
            // checking it against black would hide contrast problems.
            LinearGradient(
                colors: [Color(white: 0.42), Color(white: 0.28)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

@MainActor
func showHUDPreviewWindow() {
    NSApp.setActivationPolicy(.regular)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Plainsay HUD states"
    window.contentView = NSHostingView(rootView: HUDPreview())
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
