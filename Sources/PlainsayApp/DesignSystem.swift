import SwiftUI

/// Plainsay's visual tokens.
///
/// The HUD is read in peripheral vision for a few seconds while your attention
/// is on your own sentence, so it carries almost no text and spends its one
/// bold move on the waveform ribbon. Everything else stays quiet.
enum Palette {
    /// HUD ground. Cool near-black, never pure black — pure black reads as a
    /// hole punched in the screen.
    static let ink = Color(red: 0.078, green: 0.086, blue: 0.102)
    /// The waveform and any primary text.
    static let bone = Color(red: 0.949, green: 0.937, blue: 0.914)
    /// State labels and secondary text.
    static let slate = Color(red: 0.478, green: 0.506, blue: 0.580)
    /// Progress only — never a resting state, never a fill.
    static let signal = Color(red: 0.435, green: 0.827, blue: 0.780)
    /// Errors and the raw-fallback badge. The only warm colour in the system.
    static let ember = Color(red: 0.910, green: 0.537, blue: 0.420)
    /// Hairlines on ink.
    static let veil = Color.white.opacity(0.09)
}

enum Metrics {
    static let hudWidth: CGFloat = 340
    static let hudHeight: CGFloat = 48
    /// Distance from the bottom of the screen. High enough to clear the Dock.
    static let hudBottomInset: CGFloat = 120
    static let hudCornerRadius: CGFloat = 14
}

extension Font {
    /// Instrument label: small, monospaced, wide-tracked. Reads as a readout
    /// rather than as prose, which is what the HUD's state actually is.
    static let hudLabel = Font.system(size: 9.5, weight: .semibold, design: .monospaced)
    static let hudTimer = Font.system(size: 11, weight: .medium, design: .monospaced)
}

extension View {
    /// Wide letter-spacing for the uppercase instrument labels.
    func instrumentTracking() -> some View {
        tracking(1.1)
    }
}
