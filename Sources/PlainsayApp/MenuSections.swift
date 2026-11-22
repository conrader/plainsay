import AppKit
import SwiftUI
import PlainsayCore

extension MenuContent {
    /// Languages offered as translation targets: the ones the speaker listed,
    /// plus English, which is the overwhelmingly common target and is often
    /// not something people list as a language they *speak*.
    private var translationTargets: [String] {
        var codes = settings.spokenLanguages.map(SupportedLanguage.primaryCode)
        if !codes.contains("en") { codes.append("en") }
        return codes
    }

    private var isEntitled: Bool { coordinator.cloud.account?.isActive == true }

    /// Translation lives in the menu bar rather than in Settings because it is
    /// switched per conversation, not configured once — the whole point is
    /// reaching it without leaving what you are writing.
    @ViewBuilder
    var translationMenu: some View {
        if isEntitled {
            Menu(translationMenuTitle) {
                ForEach(translationTargets, id: \.self) { code in
                    Button {
                        // Picking a language *is* switching translation on.
                        // A separate on/off switch beside a language list is
                        // one control too many for something reached mid-task.
                        settings.translationTargetLanguage = code
                    } label: {
                        if settings.translationTargetLanguage == code {
                            Label(SupportedLanguage.named(code), systemImage: "checkmark")
                        } else {
                            Text(SupportedLanguage.named(code))
                        }
                    }
                }
                Divider()
                Button(Localization.appString("menu.translate.off", fallback: "Don't translate")) {
                    settings.translationTargetLanguage = nil
                }

                Divider()
                // The chord is a system-wide event tap, not a menu shortcut, so
                // SwiftUI cannot display it next to an item. Naming it here is
                // the only way it is ever discovered.
                Text(
                    Localization.appFormat(
                        "menu.translate.shortcut",
                        fallback: "%@ toggles translation anywhere",
                        TranslationHotkey.controlOptionCommandT.displayName
                    )
                )
            }
        } else {
            // Shown, not hidden: a feature nobody can see is a feature nobody
            // subscribes for. Disabled with the reason, so it does not read as
            // something broken.
            Button(Localization.appString("menu.translate.locked", fallback: "Translate — needs Plainsay Cloud")) {}
                .disabled(true)
        }
    }

    /// "Private next dictation" (oneshot). Shown disabled with the reason
    /// when the prepared engine is not on-device or not ready, never hidden.
    /// Arming is memory only; every launch starts disarmed.
    @ViewBuilder
    var privateDictationMenu: some View {
        let privateDictation = coordinator.privateDictation
        if privateDictation.isArmed {
            Button {
                coordinator.disarmPrivate()
            } label: {
                Label(
                    Localization.appString("menu.private.armed", fallback: "Private dictation armed — turn off"),
                    systemImage: "checkmark"
                )
            }
        } else {
            Button(Localization.appString("menu.private.arm", fallback: "Private next dictation")) {
                coordinator.armPrivateNextDictation()
            }
            .disabled(coordinator.privateRefusal != nil || coordinator.phase.isBusy)
            if let refusal = coordinator.privateRefusal {
                Text(refusal.menuReason)
            }
        }
        // While it exists, ⇧⌘C copies this rather than the newest History
        // record, which would be the previous, non-private dictation.
        if privateDictation.ephemeral.hasText {
            Button(Localization.appString("menu.private.copy", fallback: "Copy private dictation")) {
                privateDictation.ephemeral.copy()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }

    private var translationMenuTitle: String {
        guard let target = settings.translationTargetLanguage else {
            return Localization.appString("menu.translate.idle", fallback: "Translate")
        }
        return Localization.appFormat(
            "menu.translate.active", fallback: "Translating → %@", SupportedLanguage.named(target)
        )
    }
}
