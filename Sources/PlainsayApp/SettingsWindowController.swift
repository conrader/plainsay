import AppKit
import SwiftUI
import PlainsayCore

/// Owns the settings window directly rather than using SwiftUI's `Settings`
/// scene.
///
/// The scene's `showSettingsWindow:` action needs a responder chain to travel
/// up, and a menu-bar-only app has no main window to provide one — so the
/// action silently finds no target and nothing opens. An `NSWindow` we hold
/// ourselves always works.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: PlainsaySettings
    private let coordinator: DictationCoordinator
    private let permissionStatus: PermissionStatus
    private let updates: UpdateController
    private var window: NSWindow?

    init(
        settings: PlainsaySettings,
        coordinator: DictationCoordinator,
        permissionStatus: PermissionStatus,
        updates: UpdateController
    ) {
        self.settings = settings
        self.coordinator = coordinator
        self.permissionStatus = permissionStatus
        self.updates = updates
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                // Five tabs need the width; below ~600pt the toolbar collapses
                // them into an overflow menu. Resizable so the history list is
                // usable when it fills up.
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentMinSize = NSSize(width: 660, height: 460)
            window.title = Localization.appString("window.settingsTitle", fallback: "Plainsay Settings")
            window.contentView = NSHostingView(
                rootView: SettingsView(
                    settings: settings,
                    coordinator: coordinator,
                    permissionStatus: permissionStatus,
                    updates: updates
                )
            )
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        // An accessory app has to ask for focus explicitly, or the window opens
        // behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop back out of the way; this app has no business holding focus.
        NSApp.setActivationPolicy(.accessory)
    }
}
