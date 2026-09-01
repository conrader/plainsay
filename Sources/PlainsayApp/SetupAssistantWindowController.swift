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
    private let voiceEnrollment: VoiceEnrollment
    private let onSpeechConfirmed: @MainActor (Bool) -> Void
    private var window: NSWindow?

    init(
        settings: PlainsaySettings,
        coordinator: DictationCoordinator,
        permissionStatus: PermissionStatus,
        voiceEnrollment: VoiceEnrollment,
        onSpeechConfirmed: @escaping @MainActor (Bool) -> Void
    ) {
        self.settings = settings
        self.coordinator = coordinator
        self.permissionStatus = permissionStatus
        self.voiceEnrollment = voiceEnrollment
        self.onSpeechConfirmed = onSpeechConfirmed
    }

    func show() {
        settings.onboardingWasPresented = true

        if window == nil {
            // What used to be one crowded Speech step (plan cards, the
            // on-device model list, languages, and editing all on one page,
            // forcing scrolling no other step needed) is now three steps —
            // Speech, Configure, Refine — each sized to fit at this height
            // without scrolling on any display this app's macOS 15+
            // requirement runs on.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = Localization.appString("window.setupTitle", fallback: "Set Up Plainsay")
            window.contentView = NSHostingView(
                rootView: SetupAssistantView(
                    settings: settings,
                    coordinator: coordinator,
                    permissionStatus: permissionStatus,
                    voiceEnrollment: voiceEnrollment,
                    onSpeechConfirmed: onSpeechConfirmed,
                    onFinish: { [weak self] in self?.finish() }
                )
            )
            window.minSize = NSSize(width: 700, height: 660)
            window.setContentSize(NSSize(width: 760, height: 780))
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
