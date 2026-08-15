import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import IOKit.hid

/// The three TCC grants Plainsay cannot work without.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case microphone
    case accessibility
    case inputMonitoring

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    public var reason: String {
        switch self {
        case .microphone: "To record your voice while the hotkey is held."
        case .accessibility: "To paste the transcribed text into the app you're using."
        case .inputMonitoring: "To notice the hotkey while another app is focused."
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
            // Shows the prompt the first time; afterwards it is a no-op and the
            // user has to go to System Settings.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            if !isGranted { openSettings() }
        case .accessibility:
            // `kAXTrustedCheckOptionPrompt` is a global var and so not
            // concurrency-safe to reference; its value is this literal.
            let options = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            if !isGranted { openSettings() }
        }
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
