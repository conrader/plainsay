import AppKit
import SwiftUI
import PlainsayCore

/// Owns first-run setup independently from Settings so closing the assistant
/// can never accidentally count as completing it.
@MainActor
final class SetupAssistantWindowController: NSObject, NSWindowDelegate {
    private let settings: PlainsaySettings
    private let coordinator: DictationCoordinator
    private let permissionStatus: PermissionStatus
    private let onSpeechConfirmed: @MainActor (Bool) -> Void
    private var window: NSWindow?

    init(
        settings: PlainsaySettings,
        coordinator: DictationCoordinator,
        permissionStatus: PermissionStatus,
        onSpeechConfirmed: @escaping @MainActor (Bool) -> Void
    ) {
        self.settings = settings
        self.coordinator = coordinator
        self.permissionStatus = permissionStatus
        self.onSpeechConfirmed = onSpeechConfirmed
    }

    func show() {
        // Recommend Cloud only on the very first presentation. If setup was
        // interrupted after the speech choice had already been confirmed,
        // rebuilding the window must reflect the saved choice instead of
        // silently switching the draft back to Cloud.
        let preferCloudOnFirstPresentation = settings.needsOnboarding
            && !settings.onboardingWasPresented
        settings.onboardingWasPresented = true

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Set Up Plainsay"
            window.contentView = NSHostingView(
                rootView: SetupAssistantView(
                    settings: settings,
                    coordinator: coordinator,
                    permissionStatus: permissionStatus,
                    preferCloudOnFirstPresentation: preferCloudOnFirstPresentation,
                    onSpeechConfirmed: onSpeechConfirmed,
                    onFinish: { [weak self] in self?.finish() }
                )
            )
            window.minSize = NSSize(width: 700, height: 570)
            window.setContentSize(NSSize(width: 760, height: 640))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        settings.onboardingVersion = PlainsaySettings.currentOnboardingVersion
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing before the final page remains incomplete. Reaching Ready or
        // pressing Done persists the version, so the assistant will not come
        // back merely because its red window control was used.
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
