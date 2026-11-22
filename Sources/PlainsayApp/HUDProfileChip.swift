import SwiftUI
import PlainsayCore

/// `<Name> · <route>` above the HUD while a non-Default app profile's
/// dictation is in flight (SPEC.fixed §2.5). Default shows nothing, so the
/// HUD is unchanged for anyone without profiles. VoiceOver reads the chip as
/// part of the HUD's recording label instead, so this view is hidden from it.
struct HUDProfileChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.bone.opacity(0.9))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: Metrics.hudWidth)
            .background {
                ZStack {
                    VisualEffectBackground()
                    Palette.ink.opacity(0.88)
                }
            }
            .clipShape(.capsule)
            .overlay { Capsule().strokeBorder(Palette.signal.opacity(0.35), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}
