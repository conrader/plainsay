import SwiftUI
import PlainsayCore

/// Settings › History: what "Private next dictation" does and does not cover,
/// and a button to arm it. Read-only apart from the button: there is no
/// toggle and no stored preference, so every launch starts disarmed.
struct PrivateDictationSettingsSection: View {
    let coordinator: DictationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Localization.appString("settings.private.title", fallback: "Private next dictation"))
                .font(.headline)
            Text(
                Localization.appString(
                    "settings.private.explainer",
                    fallback: "Private next dictation uses only the on-device model. It skips Polishing, translation and email layout, and keeps the text and audio out of History and crash recovery. If Plainsay quits mid-dictation, that dictation is lost. \"Correct last dictation\" is unavailable afterwards, and after a confirmed paste the text is not kept on the clipboard. The app you dictate into, clipboard managers and macOS itself are outside Plainsay's control. Model downloads and update checks still use the network."
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                Localization.appString(
                    "settings.private.consumption",
                    fallback: "One finished private dictation turns this off. If it is refused, cancelled, silent or fails, it stays on until you turn it off."
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if coordinator.privateDictation.isArmed {
                    Button(Localization.appString("menu.private.armed", fallback: "Private dictation armed — turn off")) {
                        coordinator.disarmPrivate()
                    }
                } else {
                    Button(Localization.appString("settings.private.armNow", fallback: "Arm now")) {
                        coordinator.armPrivateNextDictation()
                    }
                    .disabled(coordinator.privateRefusal != nil || coordinator.phase.isBusy)
                    if let refusal = coordinator.privateRefusal {
                        Text(refusal.menuReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
