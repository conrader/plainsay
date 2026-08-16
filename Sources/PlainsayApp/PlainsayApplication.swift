import SwiftUI
import PlainsayCore

@main
struct PlainsayApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                updates: model.updates,
                coordinator: model.coordinator,
                settings: model.settings,
                permissionStatus: model.permissionStatus
            )
        } label: {
            MenuBarIcon(
                coordinator: model.coordinator,
                settings: model.settings,
                permissionStatus: model.permissionStatus
            )
        }
    }
}

/// The menu bar glyph doubles as the always-visible state light: filled while
/// listening, hollow at rest, struck through when something needs attention.
private struct MenuBarIcon: View {
    let coordinator: DictationCoordinator
    let settings: PlainsaySettings
    let permissionStatus: PermissionStatus

    var body: some View {
        Group {
            // The brand mark replaces the plain "waveform" glyph for the one
            // state most people see the most: ready and idle. Every other
            // state (recording, working, error, unavailable) keeps its
            // existing SF Symbol — those already carry meaning through shape
            // alone, which a single static mark can't add to.
            if symbol == "waveform" {
                TrayMarkView()
            } else {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var symbol: String {
        switch coordinator.phase {
        case .recording: "waveform.circle.fill"
        case .transcribing, .cleaning, .modelLoading: "waveform.circle"
        case .error: "waveform.slash"
        case .insertedRaw, .savedToClipboard: canDictate ? "waveform" : unavailableSymbol
        case .idle:
            canDictate ? "waveform" : unavailableSymbol
        }
    }

    private var unavailableSymbol: String {
        switch coordinator.modelState {
        case .downloading, .loading: "waveform.circle"
        case .failed, .idle, .ready: "waveform.slash"
        }
    }

    private var canDictate: Bool {
        coordinator.isReadyForDictation && permissionStatus.allGranted
    }

    private var accessibilityLabel: String {
        switch coordinator.phase {
        case .recording: Localization.appString("menu.a11y.listening", fallback: "Plainsay is listening")
        case .transcribing: Localization.appString("menu.a11y.transcribing", fallback: "Plainsay is transcribing")
        case .cleaning: Localization.appString("menu.a11y.polishing", fallback: "Plainsay is polishing the transcript")
        case .modelLoading: modelAccessibilityLabel
        case .error(let message):
            Localization.appFormat("menu.a11y.error", fallback: "Plainsay error: %@", message)
        case .insertedRaw:
            Localization.appString("menu.a11y.insertedRaw", fallback: "Plainsay inserted an unpolished transcript")
        case .savedToClipboard:
            Localization.appString(
                "menu.a11y.savedToClipboard",
                fallback: "Plainsay saved the dictation to the clipboard — nothing was focused to paste into"
            )
        case .idle: readinessAccessibilityLabel
        }
    }

    private var readinessAccessibilityLabel: String {
        if canDictate {
            return Localization.appString("menu.a11y.ready", fallback: "Plainsay is ready")
        }
        if settings.needsOnboarding {
            return Localization.appString(
                "menu.a11y.setupIncomplete", fallback: "Plainsay is not ready; setup is incomplete"
            )
        }
        if !permissionStatus.allGranted {
            let missing = permissionStatus.missing.map(\.title).joined(separator: ", ")
            return Localization.appFormat(
                "menu.a11y.missingPermissions", fallback: "Plainsay is not ready; missing permissions: %@", missing
            )
        }
        return modelAccessibilityLabel
    }

    private var modelAccessibilityLabel: String {
        switch coordinator.modelState {
        case .ready: Localization.appString("menu.a11y.ready", fallback: "Plainsay is ready")
        case .idle: Localization.appString("menu.a11y.notReady", fallback: "Plainsay is not ready")
        case .downloading(let progress):
            Localization.appFormat(
                "menu.a11y.downloading", fallback: "Plainsay is downloading the speech model, %d percent",
                percentage(progress)
            )
        case .loading(let progress):
            if let progress {
                Localization.appFormat(
                    "menu.a11y.preparingWithProgress",
                    fallback: "Plainsay is preparing the speech model, %d percent", percentage(progress)
                )
            } else {
                Localization.appString("menu.a11y.preparing", fallback: "Plainsay is preparing the speech model")
            }
        case .failed:
            Localization.appString(
                "menu.a11y.modelFailed", fallback: "Plainsay is not ready because the speech model failed to load"
            )
        }
    }

    private func percentage(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 100).rounded())
    }
}

struct MenuContent: View {
    let updates: UpdateController
    let coordinator: DictationCoordinator
    let settings: PlainsaySettings
    let permissionStatus: PermissionStatus

    var body: some View {
        Group {
            Text(statusLine)

            if !permissionStatus.allGranted {
                Divider()
                Text(
                    Localization.appFormat(
                        "menu.missingPermissions", fallback: "Missing permissions: %@",
                        permissionStatus.missing.map(\.title).joined(separator: ", ")
                    )
                )
                Button(fixPermissionsTitle) {
                    if settings.needsOnboarding {
                        openSetupAssistant()
                    } else {
                        openSettings()
                    }
                }
            }

            Divider()

            // The recovery path when a paste didn't land: get the words back
            // without hunting through Settings.
            if let last = coordinator.history.mostRecent, !last.text.isEmpty {
                Button("Copy last dictation") {
                    coordinator.history.copyToClipboard(last)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }

            // Distributed outside the App Store, so nothing updates this app but
            // this menu item and the scheduled check behind it.
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheck)

            if settings.needsOnboarding {
                Button("Finish Setup…") {
                    openSetupAssistant()
                }
            }

            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit Plainsay") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .environment(\.locale, Locale(identifier: Localization.resolvedCode(override: settings.interfaceLanguage)))
    }

    private var fixPermissionsTitle: String {
        settings.needsOnboarding
            ? Localization.appString("menu.continueSetup", fallback: "Continue Setup…")
            : Localization.appString("menu.fixInSettings", fallback: "Fix in Settings…")
    }

    /// One line that answers "can I dictate right now?"
    private var statusLine: String {
        if case .error(let message) = coordinator.phase {
            return Localization.appFormat("menu.status.error", fallback: "Not ready — %@", message)
        }

        if settings.needsOnboarding, coordinator.modelState == .idle {
            return Localization.appString("menu.status.finishSetup", fallback: "Finish setup to start dictation")
        }

        if !permissionStatus.allGranted, coordinator.modelState == .ready {
            return Localization.appString(
                "menu.status.grantPermissions", fallback: "Not ready — grant the missing permissions"
            )
        }

        switch coordinator.modelState {
        case .ready:
            let key: String
            switch settings.hotkeyMode {
            case .holdOnly: key = "menu.status.hold"
            case .toggleOnly: key = "menu.status.tap"
            case .hybrid: key = "menu.status.holdOrTap"
            }
            let fallback: String
            switch settings.hotkeyMode {
            case .holdOnly: fallback = "Hold %@ to dictate"
            case .toggleOnly: fallback = "Tap %@ to dictate"
            case .hybrid: fallback = "Hold or tap %@ to dictate"
            }
            return Localization.appFormat(key, fallback: fallback, settings.binding.localizedDisplayName)
        case .downloading(let progress):
            return Localization.appFormat(
                "menu.status.downloading", fallback: "Downloading speech model… %d%%", percentage(progress)
            )
        case .loading(let progress):
            if let progress {
                return Localization.appFormat(
                    "menu.status.preparingWithProgress", fallback: "Preparing speech model… %d%%",
                    percentage(progress)
                )
            }
            return Localization.appString(
                "menu.status.preparing", fallback: "Preparing speech model for this Mac…"
            )
        case .idle:
            return Localization.appString("menu.status.starting", fallback: "Starting…")
        case .failed:
            return Localization.appString("menu.status.modelFailed", fallback: "Speech model failed to load")
        }
    }

    private func percentage(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 100).rounded())
    }
}
