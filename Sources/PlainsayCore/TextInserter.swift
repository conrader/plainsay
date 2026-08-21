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
    /// Accessibility cannot identify a usable paste target (or isn't granted
    /// at all), so a synthetic ⌘V has nowhere safe to land. The text was left
    /// on the clipboard either way.
    case noFocusedElement
}

public protocol TextInserting: Sendable {
    /// - Parameter keepOnClipboard: leave the dictation on the clipboard rather
    ///   than restoring the previous contents, so a swallowed ⌘V costs one
    ///   manual paste instead of the whole dictation.
    @MainActor func insert(_ text: String, keepOnClipboard: Bool) async -> TextInsertionOutcome
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

    public init(
        pasteDelay: Duration = .milliseconds(20),
        // 150ms was too tight. A busy Electron app or browser can take longer
        // than that to service ⌘V, and restoring the old clipboard underneath
        // it means the paste lands as the *previous* clipboard contents — or as
        // nothing. That is the likeliest cause of a dictation "disappearing".
        restoreDelay: Duration = .milliseconds(600)
    ) {
        self.pasteDelay = pasteDelay
        self.restoreDelay = restoreDelay
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
        // `changeCount` increments on every write to the pasteboard, ours
        // included. Recorded right after our own write, so a mismatch later
        // means someone else — the user copying something else, another
        // app — touched it in between, not just that time passed.
        let changeCountAfterOurWrite = pasteboard.changeCount

        // Nothing focused anywhere means a synthetic ⌘V has nowhere to land.
        // Sending it anyway risks it reaching some unrelated responder, and
        // the pasteboard write above already keeps the dictation safe either
        // way, so leave it there instead of restoring the old clipboard over
        // it — that restore is exactly how a dictation used to vanish.
        guard trusted, Self.hasPossiblePasteTarget() else {
            Log.insertion.info(
                "no focused element — left \(text.count, privacy: .public) chars on the clipboard"
            )
            return .noFocusedElement
        }

        try? await Task.sleep(for: pasteDelay)
        Self.sendCommandV()

        try? await Task.sleep(for: restoreDelay)
        // Restoring unconditionally here used to silently clobber anything
        // copied during that wait — dictate something, copy something else
        // right after, and the second copy would vanish back to whatever was
        // on the clipboard before the dictation. Only restore if nothing else
        // touched the pasteboard since our own write.
        if !keepOnClipboard, pasteboard.changeCount == changeCountAfterOurWrite {
            snapshot.restore(to: pasteboard)
        }

        Log.insertion.info(
            "inserted \(text.count, privacy: .public) chars, accessibility=\(trusted, privacy: .public)"
        )
        return .inserted
    }

    /// Best-effort: a visible focused element is authoritative. If that probe
    /// is inconclusive, a focused window supplies the missing evidence; the
    /// known ChatGPT custom editor may use that fallback even when the element
    /// probe explicitly has no value.
    @MainActor
    private static func hasPossiblePasteTarget() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        let focusedElement = accessibilityValueState(
            on: systemWide,
            attribute: kAXFocusedUIElementAttribute as CFString
        )

        // A definite focused element needs no slower cross-process fallback.
        if focusedElement == .present { return true }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        let allowsFocusedWindowFallback = frontmost.bundleIdentifier == "com.openai.codex"

        // A definite missing element normally means no paste target. ChatGPT's
        // custom editor is the confirmed exception: its focused window accepts
        // ⌘V even though the editor itself can be hidden from Accessibility.
        guard focusedElement == .unknown || allowsFocusedWindowFallback else { return false }

        let focusedWindow = accessibilityValueState(
            on: AXUIElementCreateApplication(frontmost.processIdentifier),
            attribute: kAXFocusedWindowAttribute as CFString
        )

        return shouldAttemptPaste(
            focusedElement: focusedElement,
            focusedWindow: focusedWindow,
            allowsFocusedWindowFallback: allowsFocusedWindowFallback
        )
    }

    enum AccessibilityValueState: Equatable {
        case present
        case absent
        case unknown
    }

    private static func accessibilityValueState(
        on element: AXUIElement,
        attribute: CFString
    ) -> AccessibilityValueState {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return accessibilityValueState(
            queryResult: result,
            valuePresent: value != nil
        )
    }

    static func accessibilityValueState(
        queryResult: AXError,
        valuePresent: Bool
    ) -> AccessibilityValueState {
        switch queryResult {
        case .success:
            return valuePresent ? .present : .absent
        case .noValue:
            return .absent
        default:
            // `cannotComplete`, `attributeUnsupported`, and timeouts describe
            // an inconclusive probe, not proof that no editor can receive ⌘V.
            return .unknown
        }
    }

    /// Accessibility cannot expose the focused editor in every native app or
    /// app-backed web view. An inconclusive element probe still needs a focused
    /// window before we risk ⌘V. ChatGPT gets the narrower window-only fallback
    /// because its custom editor is known to omit the element entirely.
    static func shouldAttemptPaste(
        focusedElement: AccessibilityValueState,
        focusedWindow: AccessibilityValueState,
        allowsFocusedWindowFallback: Bool
    ) -> Bool {
        switch focusedElement {
        case .present:
            return true
        case .unknown:
            return focusedWindow == .present
        case .absent:
            return allowsFocusedWindowFallback && focusedWindow == .present
        }
    }

    /// Virtual keycode for `v` on any layout (ANSI position-based).
    private static let keyCodeV: CGKeyCode = 0x09

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
}
