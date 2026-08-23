import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import IOKit.hid
import Observation

/// The three TCC grants Plainsay cannot work without.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case microphone
    case accessibility
    case inputMonitoring

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: Localization.coreString("permission.title.microphone", fallback: "Microphone")
        case .accessibility: Localization.coreString("permission.title.accessibility", fallback: "Accessibility")
        case .inputMonitoring: Localization.coreString("permission.title.inputMonitoring", fallback: "Input Monitoring")
        }
    }

    public var reason: String {
        switch self {
        case .microphone:
            Localization.coreString(
                "permission.reason.microphone", fallback: "To record your voice while dictation is active."
            )
        case .accessibility:
            Localization.coreString(
                "permission.reason.accessibility",
                fallback: "To paste the transcribed text into the app you're using."
            )
        case .inputMonitoring:
            Localization.coreString(
                "permission.reason.inputMonitoring",
                fallback: """
                To notice your hotkey while you are working in another app. Plainsay watches for \
                that one key combination and nothing else — it never records what you type, and \
                keystrokes are not part of a transcript.
                """
            )
        }
    }

    /// What macOS does after the switch is flipped, where that is surprising.
    ///
    /// Accessibility and Input Monitoring do not take effect in a running
    /// process: macOS quits Plainsay so the new grant applies. Without saying
    /// so, the app vanishing mid-setup reads as a crash caused by granting.
    public var afterGranting: String? {
        switch self {
        case .microphone:
            nil
        case .accessibility, .inputMonitoring:
            Localization.coreString(
                "permission.afterGranting.relaunch",
                fallback: "macOS quits Plainsay when you flip this switch. It reopens where you left off."
            )
        }
    }

    public var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    @MainActor
    public var isGranted: Bool {
        switch self {
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            AXIsProcessTrusted()
        case .inputMonitoring:
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    /// Whether macOS still has a prompt left to show for this permission.
    ///
    /// TCC will only ever ask once. After that the switch exists in System
    /// Settings and nothing the app calls will raise a dialog again, so the
    /// honest move is to stop pretending and open the pane instead.
    @MainActor
    public var canStillPrompt: Bool {
        switch self {
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .inputMonitoring:
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown
        case .accessibility:
            // No tri-state API exists for Accessibility — `AXIsProcessTrusted`
            // cannot tell "never asked" from "asked and refused". Recording
            // that we have asked is the only way to avoid either opening
            // System Settings over a live prompt or offering a button that
            // does nothing at all.
            !UserDefaults.standard.bool(forKey: Self.accessibilityPromptedKey)
        }
    }

    private static let accessibilityPromptedKey = "com.plainsay.didPromptForAccessibility"

    /// Triggers the system prompt where one exists. Accessibility and Input
    /// Monitoring can only be granted in System Settings, so those open the pane.
    @MainActor
    public func request() async {
        switch self {
        case .microphone:
            // Two things this needs that the naive version lacks. The system
            // prompt is attached to the active app, and an accessory app is
            // often not it — so become a regular app just long enough to ask.
            // And once the user has denied it, `requestAccess` returns false
            // without showing anything, which reads as a dead button; the only
            // route left is System Settings.
            let policy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let granted = await AVCaptureDevice.requestAccess(for: .audio)

            NSApp.setActivationPolicy(policy)
            if !granted { openSettings() }
        case .inputMonitoring:
            // Opening System Settings here used to be unconditional, and it
            // fired on the line after the request — before anyone could have
            // answered. The prompt is raised asynchronously, so `isGranted`
            // was necessarily still false, and the settings window arrived on
            // top of the dialog it was meant to be the fallback for. The
            // prompt was there; it was just buried a fraction of a second
            // after appearing.
            guard canStillPrompt else {
                openSettings()
                return
            }
            // Also what registers Plainsay in the Input Monitoring list, so
            // the switch exists to flip even if this dialog is dismissed.
            withPromptActivation {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
        case .accessibility:
            guard canStillPrompt else {
                openSettings()
                return
            }
            UserDefaults.standard.set(true, forKey: Self.accessibilityPromptedKey)
            withPromptActivation {
                // `kAXTrustedCheckOptionPrompt` is a global var and so not
                // concurrency-safe to reference; its value is this literal.
                let options = ["AXTrustedCheckOptionPrompt": true]
                _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            }
        }
    }

    /// Runs `body` with Plainsay as the active regular app.
    ///
    /// TCC attaches its dialog to the active application. Plainsay lives in
    /// the menu bar as an accessory, which often is not it — so the prompt
    /// opens behind whatever the user was looking at, or does not appear to
    /// open at all. The microphone path has always done this; the other two
    /// needed it just as much.
    @MainActor
    private func withPromptActivation(_ body: () -> Void) {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        body()
        NSApp.setActivationPolicy(policy)
    }

    @MainActor
    public func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

@MainActor
public enum Permissions {
    public static var missing: [Permission] {
        Permission.allCases.filter { !$0.isGranted }
    }

    public static var allGranted: Bool { missing.isEmpty }
}

/// Observable TCC snapshot for UI that must change when the user returns from
/// System Settings. Reading the system APIs directly is not observable, so a
/// menu-bar label can otherwise stay stale until unrelated app state changes.
@MainActor
@Observable
public final class PermissionStatus {
    private var grants: [Permission: Bool]

    public init() {
        grants = Dictionary(
            uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) }
        )
    }

    public var allGranted: Bool {
        Permission.allCases.allSatisfy { grants[$0] == true }
    }

    public var missing: [Permission] {
        Permission.allCases.filter { grants[$0] != true }
    }

    public func isGranted(_ permission: Permission) -> Bool {
        grants[permission] == true
    }

    public func refresh() {
        let current = Dictionary(
            uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) }
        )
        if current != grants { grants = current }
    }
}
