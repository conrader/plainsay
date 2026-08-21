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
                fallback: "Could not listen for the hotkey. Grant Plainsay access in System Settings › Privacy & Security › Input Monitoring, then restart it."
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
    /// Called once when Escape is pressed. The event remains visible to the
    /// frontmost app because this monitor is deliberately listen-only.
    public var onCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

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
            // Listen-only: we must not swallow the key, or binding Right ⌘ would
            // break every ⌘-shortcut typed with the right hand.
            options: .listenOnly,
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
    func handle(type: CGEventType, keyCode: UInt16, flags: UInt64, isAutorepeat: Bool) {
        if type == .keyDown, keyCode == Self.escapeKeyCode {
            // A held Escape key repeats. One cancellation is enough, and
            // avoiding repeats keeps an Escape intended for the next session
            // from being inferred from the same physical press.
            guard !isAutorepeat else { return }
            onCancel?()
            return
        }

        guard keyCode == binding.keyCode else { return }

        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .flagsChanged:
            guard binding.isModifier else { return }
            let pressed = binding.isPressed(flags: flags)
            guard pressed != isDown else { return }
            isDown = pressed
            emit(pressed ? .down(at: now) : .up(at: now))

        case .keyDown:
            guard !binding.isModifier else { return }
            // Ignore auto-repeat: a held key must read as one long press.
            guard !isAutorepeat, !isDown else { return }
            isDown = true
            emit(.down(at: now))

        case .keyUp:
            guard !binding.isModifier, isDown else { return }
            isDown = false
            emit(.up(at: now))

        default:
            break
        }
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

    MainActor.assumeIsolated {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            monitor.reenable()
        default:
            monitor.handle(type: type, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        }
    }

    return Unmanaged.passUnretained(event)
}
