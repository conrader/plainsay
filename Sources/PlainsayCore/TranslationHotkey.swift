import CoreGraphics
import Foundation

/// The chord that switches translation on and off without leaving what you're
/// writing.
///
/// Deliberately a separate type from `HotkeyBinding` rather than an extension
/// of it. That type describes the dictation key — a single key or bare
/// modifier, watched for press *and release*, and never consumed so the
/// foreground app still receives it. This is the opposite on every count: a
/// chord, edge-triggered on key-down only, and consumed so the shortcut does
/// not also type a "t" into whatever is in front. Widening one type to cover
/// both would have put a rarely-used convenience inside the code path the whole
/// app depends on.
public struct TranslationHotkey: Sendable, Equatable {
    public let keyCode: UInt16
    /// Every one of these must be held. Matching on a superset would fire on
    /// chords the user meant for something else.
    public let requiredFlags: CGEventFlags

    public init(keyCode: UInt16, requiredFlags: CGEventFlags) {
        self.keyCode = keyCode
        self.requiredFlags = requiredFlags
    }

    /// ⌃⌥⌘T. Chosen for being almost universally unclaimed: ⇧⌘T is "reopen
    /// closed tab" in every browser, and taking that would break something
    /// people use constantly, system-wide, to save one modifier.
    public static let controlOptionCommandT = TranslationHotkey(
        keyCode: 17,  // t
        requiredFlags: [.maskControl, .maskAlternate, .maskCommand]
    )

    public var displayName: String { "⌃⌥⌘T" }

    /// Whether `flags` holds exactly the chord — all of it, and no other
    /// modifier that would make this a different shortcut.
    func matches(flags: UInt64) -> Bool {
        let interesting: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        let held = CGEventFlags(rawValue: flags).intersection(interesting)
        return held == requiredFlags.intersection(interesting)
    }
}
