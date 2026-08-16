import AppKit
import Foundation

/// The key that triggers dictation.
///
/// Modifier keys are the good choice here — they are the only keys you can hold
/// for several seconds without an app doing something about it — so they are
/// first-class rather than an afterthought.
public struct HotkeyBinding: Codable, Sendable, Hashable, Identifiable {
    public var keyCode: UInt16
    /// Device-dependent modifier bit used to tell press from release in
    /// `flagsChanged` events. Nil for ordinary keys.
    public var modifierMask: UInt64?
    public var displayName: String

    public var id: UInt16 { keyCode }
    public var isModifier: Bool { modifierMask != nil }

    public init(keyCode: UInt16, modifierMask: UInt64?, displayName: String) {
        self.keyCode = keyCode
        self.modifierMask = modifierMask
        self.displayName = displayName
    }

    // Device-dependent modifier masks. AppKit exposes only the merged flags
    // (`.command`), which cannot distinguish left from right; these raw bits can.
    private static let leftControl: UInt64 = 0x0000_0001
    private static let leftShift: UInt64 = 0x0000_0002
    private static let rightShift: UInt64 = 0x0000_0004
    private static let leftCommand: UInt64 = 0x0000_0008
    private static let rightCommand: UInt64 = 0x0000_0010
    private static let leftOption: UInt64 = 0x0000_0020
    private static let rightOption: UInt64 = 0x0000_0040
    private static let rightControl: UInt64 = 0x0000_2000
    private static let function: UInt64 = UInt64(NSEvent.ModifierFlags.function.rawValue)

    public static let rightCommandKey = HotkeyBinding(
        keyCode: 54, modifierMask: rightCommand, displayName: "Right ⌘"
    )
    public static let leftCommandKey = HotkeyBinding(
        keyCode: 55, modifierMask: leftCommand, displayName: "Left ⌘"
    )
    public static let rightOptionKey = HotkeyBinding(
        keyCode: 61, modifierMask: rightOption, displayName: "Right ⌥"
    )
    public static let leftOptionKey = HotkeyBinding(
        keyCode: 58, modifierMask: leftOption, displayName: "Left ⌥"
    )
    public static let rightControlKey = HotkeyBinding(
        keyCode: 62, modifierMask: rightControl, displayName: "Right ⌃"
    )
    public static let fnKey = HotkeyBinding(
        keyCode: 63, modifierMask: function, displayName: "Fn (Globe)"
    )
    public static let f13Key = HotkeyBinding(
        keyCode: 105, modifierMask: nil, displayName: "F13"
    )

    public static let presets: [HotkeyBinding] = [
        .rightCommandKey, .rightOptionKey, .rightControlKey,
        .leftOptionKey, .fnKey, .f13Key,
    ]

    /// Whether this key is currently held, given a `flagsChanged` event's flags.
    func isPressed(flags: UInt64) -> Bool {
        guard let modifierMask else { return false }
        return flags & modifierMask != 0
    }

    /// `displayName` stays a stored, English literal: it round-trips through
    /// `Codable` as part of `PlainsaySettings.binding`'s persisted JSON, so
    /// turning it into a computed lookup would either break decoding an
    /// existing user's saved hotkey or require a hand-written `Codable`
    /// conformance just to ignore it. This is the one other code should
    /// display instead — keyed by `keyCode`, so it works for any of the
    /// presets above regardless of which `displayName` an older save has.
    public var localizedDisplayName: String {
        switch keyCode {
        case Self.rightCommandKey.keyCode: Localization.coreString("hotkey.name.rightCommand", fallback: "Right ⌘")
        case Self.leftCommandKey.keyCode: Localization.coreString("hotkey.name.leftCommand", fallback: "Left ⌘")
        case Self.rightOptionKey.keyCode: Localization.coreString("hotkey.name.rightOption", fallback: "Right ⌥")
        case Self.leftOptionKey.keyCode: Localization.coreString("hotkey.name.leftOption", fallback: "Left ⌥")
        case Self.rightControlKey.keyCode: Localization.coreString("hotkey.name.rightControl", fallback: "Right ⌃")
        case Self.fnKey.keyCode: Localization.coreString("hotkey.name.fn", fallback: "Fn (Globe)")
        case Self.f13Key.keyCode: Localization.coreString("hotkey.name.f13", fallback: "F13")
        default: displayName
        }
    }
}
