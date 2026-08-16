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
    let permissionStatus = PermissionStatus()
    /// Owns Sparkle. Created once here so the scheduled check starts at launch
    /// rather than only when a menu happens to be drawn.
    let updates = UpdateController()
    let hud: HUDController
    let settingsWindow: SettingsWindowController
    lazy var setupAssistantWindow: SetupAssistantWindowController = {
        SetupAssistantWindowController(
            settings: settings,
            coordinator: coordinator,
            permissionStatus: permissionStatus,
            onSpeechConfirmed: { [weak self] selectionChanged in
                self?.prepareSelectedSpeechModelFromSetup(selectionChanged: selectionChanged)
            }
        )
    }()

    private var startTask: Task<Void, Never>?

    private init() {
        let settings = PlainsaySettings.shared
        let coordinator = DictationCoordinator(settings: settings)
        self.coordinator = coordinator
        self.hud = HUDController(coordinator: coordinator)
        self.settingsWindow = SettingsWindowController(
            settings: settings,
            coordinator: coordinator,
            permissionStatus: permissionStatus,
            updates: updates
        )
    }

    /// Starts the long-lived services once. Setup and normal launch can race
    /// here without installing two hotkey monitors or loading two models.
    func start(requestMicrophonePermission: Bool = true) async {
        if let startTask {
            await startTask.value
            return
        }

        hud.start()
        let task = Task { @MainActor [coordinator] in
            await coordinator.start(requestMicrophonePermission: requestMicrophonePermission)
        }
        startTask = task
        await task.value
    }

    /// The model choice is deliberately confirmed before startup: first-run
    /// setup must never download the default model while the user is still
    /// deciding. Re-running setup reloads an already-running coordinator.
    private func prepareSelectedSpeechModelFromSetup(selectionChanged: Bool) {
        if startTask == nil {
            Task { await start(requestMicrophonePermission: false) }
        } else if selectionChanged || coordinator.modelState == .idle {
            Task { await coordinator.reloadModel() }
        } else if case .failed = coordinator.modelState {
            Task { await coordinator.reloadModel() }
        }
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
            let model = AppModel.shared
            model.permissionStatus.refresh()
            model.settings.migrateLegacyOnboardingIfNeeded(
                allPermissionsGranted: model.permissionStatus.allGranted
            )

            if model.settings.needsOnboarding {
                // Let the menu-bar scene finish mounting before bringing its
                // companion first-run window forward.
                try? await Task.sleep(for: .milliseconds(250))
                openSetupAssistant()
                return
            }

            // Without all three grants the app is inert, so say so immediately
            // rather than letting the first hotkey press fail silently.
            if !model.permissionStatus.allGranted {
                // The Settings scene does not exist yet at
                // `didFinishLaunching`; give SwiftUI a beat to install it.
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            // Permission buttons own every system prompt. Launch can prepare
            // the selected model, but must not surprise the user with one.
            await model.start(requestMicrophonePermission: false)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.permissionStatus.refresh()
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

@MainActor
func openSetupAssistant() {
    AppModel.shared.setupAssistantWindow.show()
}
