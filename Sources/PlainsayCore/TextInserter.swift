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
    /// There *was* somewhere to paste, but not where the dictation was aimed:
    /// the app quit, focus would not come back, or a different window of it is
    /// in front now. No ⌘V was sent. The text is on the clipboard.
    ///
    /// Produced by `DictationCoordinator`, not by an inserter — which window a
    /// dictation belongs to is a fact about the dictation, not about the
    /// mechanics of pasting.
    case targetUnavailable(PasteTargetLoss)
    /// ⌘V was sent, but Accessibility could not show a focused text field —
    /// only a focused window vouched for it (an Electron app, or an unreadable
    /// probe). The paste may have landed nowhere, so the dictation was left on
    /// the clipboard instead of the previous contents being put back.
    case insertedUnconfirmed

    /// ⌘V was sent, whether or not a text field was seen to take it.
    public var sentPaste: Bool { self == .inserted || self == .insertedUnconfirmed }
}

/// How sure Accessibility is that ⌘V has a text field to land in.
enum PasteTargetCertainty: Equatable {
    /// Nothing that could take a paste. No ⌘V is sent.
    case none
    /// Only a focused window vouches for it. ⌘V is sent, but may land nowhere.
    case unconfirmed
    /// A focused element answered.
    case confirmed
}

public protocol TextInserting: Sendable {
    /// - Parameter keepOnClipboard: leave the dictation on the clipboard rather
    ///   than restoring the previous contents, so a swallowed ⌘V costs one
    ///   manual paste instead of the whole dictation.
    @MainActor func insert(_ text: String, keepOnClipboard: Bool) async -> TextInsertionOutcome

    /// Put the text on the clipboard and stop there: no ⌘V, and no restoring
    /// of the previous contents afterwards.
    ///
    /// For when there is a paste target but it is the wrong one. The dictation
    /// becomes the clipboard's contents and stays there — `keepOnClipboard`
    /// does not apply, because here the clipboard is the only copy there is.
    @MainActor func copyToClipboard(_ text: String)
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
        let certainty = trusted ? Self.pasteTargetCertainty() : .none
        guard certainty != .none else {
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
        if Self.restoresPreviousClipboard(certainty: certainty, keepOnClipboard: keepOnClipboard),
           pasteboard.changeCount == changeCountAfterOurWrite {
            snapshot.restore(to: pasteboard)
        }

        Log.insertion.info(
            "inserted \(text.count, privacy: .public) chars, accessibility=\(trusted, privacy: .public)"
        )
        return certainty == .confirmed ? .inserted : .insertedUnconfirmed
    }

    @MainActor
    public func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        // No snapshot and no restore, deliberately. The previous clipboard is
        // overwritten and stays overwritten, exactly as on the
        // `.noFocusedElement` path above: restoring over a dictation that has
        // nowhere else to live is how a dictation disappears.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Log.insertion.info(
            "left \(text.count, privacy: .public) chars on the clipboard without pasting"
        )
    }

    /// Best-effort: a visible focused element is authoritative. If that probe
    /// is inconclusive, a focused window supplies the missing evidence; the
    /// known ChatGPT custom editor and Electron apps may use that fallback
    /// even when the element probe explicitly has no value.
    @MainActor
    private static func pasteTargetCertainty() -> PasteTargetCertainty {
        let systemWide = AXUIElementCreateSystemWide()
        let focusedElement = accessibilityValueState(
            on: systemWide,
            attribute: kAXFocusedUIElementAttribute as CFString
        )

        // A definite focused element needs no slower cross-process fallback.
        if focusedElement == .present { return .confirmed }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return .none }
        let allowsFocusedWindowFallback = Self.allowsFocusedWindowFallback(
            bundleIdentifier: frontmost.bundleIdentifier,
            bundleURL: frontmost.bundleURL
        )

        // A definite missing element normally means no paste target. ChatGPT's
        // custom editor and Electron apps are the exceptions: their focused
        // window accepts ⌘V even though the editor can be hidden from
        // Accessibility.
        guard focusedElement == .unknown || allowsFocusedWindowFallback else { return .none }

        let focusedWindow = accessibilityValueState(
            on: AXUIElementCreateApplication(frontmost.processIdentifier),
            attribute: kAXFocusedWindowAttribute as CFString
        )

        return pasteTargetCertainty(
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

    /// Whether a focused window is enough evidence of somewhere to paste when
    /// the focused-element probe definitely came back empty.
    ///
    /// Electron apps are the general case of the ChatGPT one: Chromium keeps
    /// its accessibility tree switched off until an assistive app asks for
    /// it, so "no focused element" from one of them says nothing about
    /// whether a text field has the caret. Grok Bot sent every dictation to
    /// the clipboard this way while its field never lost focus.
    static func allowsFocusedWindowFallback(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        if bundleIdentifier == "com.openai.codex" { return true }
        guard let bundleURL else { return false }
        return isElectronApp(at: bundleURL)
    }

    static func isElectronApp(at bundleURL: URL) -> Bool {
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// Accessibility cannot expose the focused editor in every native app or
    /// app-backed web view. An inconclusive element probe still needs a focused
    /// window before we risk ⌘V. ChatGPT and Electron apps get the narrower
    /// window-only fallback because their editors can omit the element entirely.
    static func shouldAttemptPaste(
        focusedElement: AccessibilityValueState,
        focusedWindow: AccessibilityValueState,
        allowsFocusedWindowFallback: Bool
    ) -> Bool {
        pasteTargetCertainty(
            focusedElement: focusedElement,
            focusedWindow: focusedWindow,
            allowsFocusedWindowFallback: allowsFocusedWindowFallback
        ) != .none
    }

    /// Only a focused element confirms a text field. A focused window standing
    /// in for one is enough to try ⌘V, not enough to trust it landed.
    static func pasteTargetCertainty(
        focusedElement: AccessibilityValueState,
        focusedWindow: AccessibilityValueState,
        allowsFocusedWindowFallback: Bool
    ) -> PasteTargetCertainty {
        switch focusedElement {
        case .present:
            return .confirmed
        case .unknown:
            return focusedWindow == .present ? .unconfirmed : .none
        case .absent:
            return allowsFocusedWindowFallback && focusedWindow == .present ? .unconfirmed : .none
        }
    }

    /// Whether the clipboard from before the dictation is put back after ⌘V.
    /// Not after an unconfirmed paste: if that ⌘V landed nowhere, the restore
    /// would leave the dictation only in History.
    static func restoresPreviousClipboard(certainty: PasteTargetCertainty, keepOnClipboard: Bool) -> Bool {
        !keepOnClipboard && certainty == .confirmed
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
