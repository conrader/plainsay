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

public protocol TextInserting: Sendable {
    /// - Parameter keepOnClipboard: leave the dictation on the clipboard rather
    ///   than restoring the previous contents, so a swallowed ⌘V costs one
    ///   manual paste instead of the whole dictation.
    @MainActor func insert(_ text: String, keepOnClipboard: Bool) async
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
    public func insert(_ text: String, keepOnClipboard: Bool) async {
        guard !text.isEmpty else { return }

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

        try? await Task.sleep(for: pasteDelay)
        Self.sendCommandV()

        try? await Task.sleep(for: restoreDelay)
        if !keepOnClipboard {
            snapshot.restore(to: pasteboard)
        }

        Log.insertion.info(
            "inserted \(text.count, privacy: .public) chars, accessibility=\(trusted, privacy: .public)"
        )
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
