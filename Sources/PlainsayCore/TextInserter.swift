import AppKit
import ApplicationServices
import Foundation

/// A deep copy of the pasteboard's contents, taken before we clobber it.
///
/// `NSPasteboardItem`s belonging to the general pasteboard are invalidated by
/// `clearContents()`, so the data has to be copied out eagerly rather than held
/// by reference.
public struct PasteboardSnapshot: Sendable {
    /// One dictionary per item: pasteboard type → raw data.
    let items: [[String: Data]]

    public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    public static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type.rawValue] = data
                }
            }
            return copy
        }
        return PasteboardSnapshot(items: items)
    }

    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !isEmpty else { return }

        let restored = items.compactMap { dict -> NSPasteboardItem? in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        guard !restored.isEmpty else { return }
        pasteboard.writeObjects(restored)
    }
}

public enum TextInsertionOutcome: Sendable, Equatable {
    /// ⌘V was sent into a focused element. This does not guarantee the target
    /// app actually consumed it — nothing can, short of reading its contents
    /// back — but it is the normal, expected case.
    case inserted
    /// The Accessibility API positively reports no focused UI element (or
    /// Accessibility isn't granted at all), so a synthetic ⌘V has nowhere to
    /// land. The text was left on the clipboard either way.
    case noFocusedElement
}

public protocol TextInserting: Sendable {
    /// - Parameter keepOnClipboard: leave the dictation on the clipboard rather
    ///   than restoring the previous contents, so a swallowed ⌘V costs one
    ///   manual paste instead of the whole dictation.
    @MainActor func insert(_ text: String, keepOnClipboard: Bool) async -> TextInsertionOutcome

    /// Deletes `count` characters immediately before the caret via synthetic
    /// backspace. Used to walk live-typed text back to a common prefix before
    /// pasting a revision — never touches the pasteboard.
    @MainActor func deleteBackward(_ count: Int) async
}

/// Inserts text by writing it to the pasteboard and synthesizing ⌘V.
///
/// The Accessibility API (`kAXSelectedTextAttribute`) would be tidier, but it
/// fails silently in Electron apps, web views, and most terminals. Pasting works
/// everywhere; the cost is briefly borrowing the pasteboard, which we give back.
public struct PasteboardTextInserter: TextInserting {
    /// How long to let the target app read the pasteboard before restoring it.
    private let restoreDelay: Duration
    /// Gap between writing the pasteboard and sending ⌘V.
    private let pasteDelay: Duration
    /// Gap between consecutive synthetic backspace keystrokes.
    private let keystrokeDelay: Duration

    public init(
        pasteDelay: Duration = .milliseconds(20),
        // 150ms was too tight. A busy Electron app or browser can take longer
        // than that to service ⌘V, and restoring the old clipboard underneath
        // it means the paste lands as the *previous* clipboard contents — or as
        // nothing. That is the likeliest cause of a dictation "disappearing".
        restoreDelay: Duration = .milliseconds(600),
        // Live typing walks a run of live-typed text back with one backspace
        // per character before pasting a revision, and every live-preview
        // pass — not just the final one — can trigger this, so a long
        // dictation can mean many bursts of dozens of backspaces each. Sent
        // with zero gap, some real apps drop or coalesce keystrokes in a
        // burst like that; a dropped backspace desyncs our model of what's
        // actually on screen from what's really there, and every later delta
        // in that dictation is then computed against a wrong baseline —
        // corruption compounds instead of self-correcting. Reported by
        // Konrad as capitalization glitches and missing spaces in live
        // typing (2026-08-17).
        keystrokeDelay: Duration = .milliseconds(8)
    ) {
        self.pasteDelay = pasteDelay
        self.restoreDelay = restoreDelay
        self.keystrokeDelay = keystrokeDelay
    }

    @MainActor
    public func insert(_ text: String, keepOnClipboard: Bool) async -> TextInsertionOutcome {
        guard !text.isEmpty else { return .inserted }

        // Without Accessibility, `CGEvent.post` is silently dropped: the
        // pasteboard gets the text, no ⌘V ever arrives, and we then restore the
        // old clipboard over it. That is exactly how a dictation disappears
        // without a trace, so it is worth its own log line.
        let trusted = AXIsProcessTrusted()
        if !trusted {
            Log.insertion.error("Accessibility not granted — ⌘V will be dropped and the text will be lost")
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Nothing focused anywhere means a synthetic ⌘V has nowhere to land.
        // Sending it anyway risks it reaching some unrelated responder, and
        // the pasteboard write above already keeps the dictation safe either
        // way, so leave it there instead of restoring the old clipboard over
        // it — that restore is exactly how a dictation used to vanish.
        guard trusted, Self.hasFocusedElement() else {
            Log.insertion.info(
                "no focused element — left \(text.count, privacy: .public) chars on the clipboard"
            )
            return .noFocusedElement
        }

        try? await Task.sleep(for: pasteDelay)
        Self.sendCommandV()

        try? await Task.sleep(for: restoreDelay)
        if !keepOnClipboard {
            snapshot.restore(to: pasteboard)
        }

        Log.insertion.info(
            "inserted \(text.count, privacy: .public) chars, accessibility=\(trusted, privacy: .public)"
        )
        return .inserted
    }

    /// Best-effort: only reports "no focus" when the Accessibility API
    /// positively confirms it. Any error, timeout, or app that simply doesn't
    /// answer this query reports a focus, so a paste that would have worked
    /// is never second-guessed into a false "nothing focused" warning.
    @MainActor
    private static func hasFocusedElement() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        )
        return result == .success && focused != nil
    }

    @MainActor
    public func deleteBackward(_ count: Int) async {
        guard count > 0, AXIsProcessTrusted(), Self.hasFocusedElement() else { return }
        for _ in 0..<count {
            Self.sendDelete()
            try? await Task.sleep(for: keystrokeDelay)
        }
    }

    /// Virtual keycode for `v` on any layout (ANSI position-based).
    private static let keyCodeV: CGKeyCode = 0x09
    /// Virtual keycode for Delete/Backspace (ANSI position-based).
    private static let keyCodeDelete: CGKeyCode = 0x33

    @MainActor
    static func sendCommandV() {
        // `.combinedSessionState` makes the synthetic event inherit the real
        // session's state, so we don't have to fight physically-held modifiers.
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    @MainActor
    static func sendDelete() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeDelete, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeDelete, keyDown: false)

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
