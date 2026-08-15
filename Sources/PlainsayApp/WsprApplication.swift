import SwiftUI
import PlainsayCore

@main
struct PlainsayApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: model.coordinator, settings: model.settings)
        } label: {
            MenuBarIcon(coordinator: model.coordinator)
        }
    }
}

/// The menu bar glyph doubles as the always-visible state light: filled while
/// listening, hollow at rest, struck through when something needs attention.
private struct MenuBarIcon: View {
    let coordinator: DictationCoordinator

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
    }

    private var symbol: String {
        switch coordinator.phase {
        case .recording: "waveform.circle.fill"
        case .transcribing, .cleaning: "waveform.circle"
        case .error: "waveform.slash"
        case .insertedRaw, .idle: "waveform"
        }
    }
}

struct MenuContent: View {
    let coordinator: DictationCoordinator
    let settings: PlainsaySettings

    var body: some View {
        Text(statusLine)

        if !Permissions.allGranted {
            Divider()
            Text("Missing permissions: \(Permissions.missing.map(\.title).joined(separator: ", "))")
            Button("Fix in Settings…") {
                openSettings()
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
        switch coordinator.modelState {
        case .ready:
            switch settings.hotkeyMode {
            case .holdOnly: "Hold \(settings.binding.displayName) to dictate"
            case .toggleOnly: "Tap \(settings.binding.displayName) to dictate"
            case .hybrid: "Hold or tap \(settings.binding.displayName) to dictate"
            }
        case .downloading:
            "Downloading \(settings.model.approximateSize) speech model…"
        case .loading:
            "Loading speech model…"
        case .idle:
            "Starting…"
        case .failed:
            "Speech model failed to load"
        }
    }
}
