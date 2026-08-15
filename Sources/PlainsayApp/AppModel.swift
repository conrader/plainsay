import AppKit
import SwiftUI
import PlainsayCore

/// Single owner of the app's long-lived objects, so the scenes and the app
/// delegate are looking at the same coordinator.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings = PlainsaySettings.shared
    let coordinator: DictationCoordinator
    let hud: HUDController
    let settingsWindow: SettingsWindowController

    private init() {
        let settings = PlainsaySettings.shared
        let coordinator = DictationCoordinator(settings: settings)
        self.coordinator = coordinator
        self.hud = HUDController(coordinator: coordinator)
        self.settingsWindow = SettingsWindowController(settings: settings, coordinator: coordinator)
    }

    func start() async {
        hud.start()
        await coordinator.start()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        // Design review mode: render the HUD's states and start nothing else.
        if ProcessInfo.processInfo.environment["WSPR_HUD_PREVIEW"] == "1" {
            MainActor.assumeIsolated { showHUDPreviewWindow() }
            return
        }

        Task { @MainActor in
            // Without all three grants the app is inert, so say so immediately
            // rather than letting the first hotkey press fail silently.
            if !Permissions.allGranted {
                // The Settings scene does not exist yet at
                // `didFinishLaunching`; give SwiftUI a beat to install it.
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            await AppModel.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.coordinator.stop()
            AppModel.shared.hud.stop()
        }
    }
}

@MainActor
func openSettings() {
    AppModel.shared.settingsWindow.show()
}
