import AppKit
import Foundation
import IOKit.hid

public enum HotkeyMonitorError: LocalizedError {
    case tapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .tapCreationFailed:
            Localization.coreString(
                "hotkey.tapCreationFailed",
                fallback: "Could not listen for the hotkey. Grant Plainsay Accessibility and Input Monitoring access in System Settings › Privacy & Security, then restart it."
            )
        }
    }
}

/// Watches for the dictation hotkey system-wide via a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitorForEvents` because we
/// need key *release*, and because modifier-only bindings arrive as
/// `flagsChanged` rather than key events.
@MainActor
public final class HotkeyMonitor {
    public var binding: HotkeyBinding {
        didSet {
            guard binding != oldValue else { return }
            // A binding swap mid-press would otherwise strand us mid-recording.
            if isDown { emit(.up(at: ProcessInfo.processInfo.systemUptime)) }
            isDown = false
            restartIfRunning()
        }
    }

    /// Called on the main actor for every press and release of the bound key.
    public var onEdge: ((HotkeyEdge) -> Void)?
    /// Called once when Escape is pressed. Returning `true` means an active
    /// dictation was cancelled and the complete Escape press should be kept
    /// away from the frontmost app. Returning `false` leaves Escape alone.
    public var onCancel: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    /// If the cancelling key-down was consumed, consume its repeats and key-up
    /// too. Delivering only half a key press to another app can strand its own
    /// keyboard state or trigger an unrelated Escape action on release.
    private var consumesEscapeSequence = false

    static let escapeKeyCode: UInt16 = 53

    public private(set) var isRunning = false

    public init(binding: HotkeyBinding = .rightCommandKey) {
        self.binding = binding
    }

    // No deinit teardown: the tap and run loop source are main-actor state, and
    // a nonisolated deinit cannot touch them. Callers use `stop()`, which the
    // coordinator does on termination.

    public static func inputMonitoringAuthorized() -> Bool {
        // A tap can be created but stays disabled without permission; asking
        // the HID system directly is the reliable check.
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    public static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public func start() throws {
        guard !isRunning else { return }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active so an Escape that really cancels dictation can be kept
            // from also dismissing a sheet or modal in the destination app.
            // Every hotkey event and every idle Escape is still returned.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: context
        ) else {
            throw HotkeyMonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isDown = false
        consumesEscapeSequence = false
        isRunning = false
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        stop()
        try? start()
    }

    /// Re-arms the tap after the system disables it (which it does if our main
    /// thread ever blocks long enough to time out).
    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Takes plain scalars rather than the `CGEvent` itself: the event is not
    /// `Sendable`, and everything we need from it is read on the tap's thread.
    @discardableResult
    func handle(type: CGEventType, keyCode: UInt16, flags: UInt64, isAutorepeat: Bool) -> Bool {
        if keyCode == Self.escapeKeyCode {
            switch type {
            case .keyDown:
                if isAutorepeat { return consumesEscapeSequence }
                consumesEscapeSequence = onCancel?() == true
                return consumesEscapeSequence
            case .keyUp:
                let consume = consumesEscapeSequence
                consumesEscapeSequence = false
                return consume
            default:
                return false
            }
        }

        guard keyCode == binding.keyCode else { return false }

        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .flagsChanged:
            guard binding.isModifier else { return false }
            let pressed = binding.isPressed(flags: flags)
            guard pressed != isDown else { return false }
            isDown = pressed
            emit(pressed ? .down(at: now) : .up(at: now))

        case .keyDown:
            guard !binding.isModifier else { return false }
            // Ignore auto-repeat: a held key must read as one long press.
            guard !isAutorepeat, !isDown else { return false }
            isDown = true
            emit(.down(at: now))

        case .keyUp:
            guard !binding.isModifier, isDown else { return false }
            isDown = false
            emit(.up(at: now))

        default:
            break
        }

        // The configured dictation hotkey must always remain available to the
        // foreground app (for example Right Command in normal shortcuts).
        return false
    }

    private func emit(_ edge: HotkeyEdge) {
        onEdge?(edge)
    }
}

/// C callback trampoline. Runs on the main run loop, since that is where the
/// tap's source is attached.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // Read everything off the event here; only scalars cross into the closure.
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    let shouldConsume = MainActor.assumeIsolated {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            monitor.reenable()
            return false
        default:
            return monitor.handle(type: type, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        }
    }

    return shouldConsume ? nil : Unmanaged.passUnretained(event)
}
