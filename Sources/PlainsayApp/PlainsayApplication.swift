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
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
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
        case .recording: "Plainsay is listening"
        case .transcribing: "Plainsay is transcribing"
        case .cleaning: "Plainsay is polishing the transcript"
        case .modelLoading: modelAccessibilityLabel
        case .error(let message): "Plainsay error: \(message)"
        case .insertedRaw: "Plainsay inserted an unpolished transcript"
        case .savedToClipboard: "Plainsay saved the dictation to the clipboard — nothing was focused to paste into"
        case .idle: readinessAccessibilityLabel
        }
    }

    private var readinessAccessibilityLabel: String {
        if canDictate {
            return "Plainsay is ready"
        }
        if settings.needsOnboarding {
            return "Plainsay is not ready; setup is incomplete"
        }
        if !permissionStatus.allGranted {
            let missing = permissionStatus.missing.map(\.title).joined(separator: ", ")
            return "Plainsay is not ready; missing permissions: \(missing)"
        }
        return modelAccessibilityLabel
    }

    private var modelAccessibilityLabel: String {
        return switch coordinator.modelState {
        case .ready: "Plainsay is ready"
        case .idle: "Plainsay is not ready"
        case .downloading(let progress):
            "Plainsay is downloading the speech model, \(percentage(progress)) percent"
        case .loading(let progress):
            if let progress {
                "Plainsay is preparing the speech model, \(percentage(progress)) percent"
            } else {
                "Plainsay is preparing the speech model"
            }
        case .failed: "Plainsay is not ready because the speech model failed to load"
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
        Text(statusLine)

        if !permissionStatus.allGranted {
            Divider()
            Text("Missing permissions: \(permissionStatus.missing.map(\.title).joined(separator: ", "))")
            Button(settings.needsOnboarding ? "Continue Setup…" : "Fix in Settings…") {
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

    /// One line that answers "can I dictate right now?"
    private var statusLine: String {
        if case .error(let message) = coordinator.phase {
            return "Not ready — \(message)"
        }

        if settings.needsOnboarding, coordinator.modelState == .idle {
            return "Finish setup to start dictation"
        }

        if !permissionStatus.allGranted, coordinator.modelState == .ready {
            return "Not ready — grant the missing permissions"
        }

        return switch coordinator.modelState {
        case .ready:
            switch settings.hotkeyMode {
            case .holdOnly: "Hold \(settings.binding.displayName) to dictate"
            case .toggleOnly: "Tap \(settings.binding.displayName) to dictate"
            case .hybrid: "Hold or tap \(settings.binding.displayName) to dictate"
            }
        case .downloading(let progress):
            "Downloading speech model… \(percentage(progress))%"
        case .loading(let progress):
            if let progress {
                "Preparing speech model… \(percentage(progress))%"
            } else {
                "Preparing speech model for this Mac…"
            }
        case .idle:
            "Starting…"
        case .failed:
            "Speech model failed to load"
        }
    }

    private func percentage(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 100).rounded())
    }
}
