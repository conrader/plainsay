import AppKit
import Foundation
import Observation

/// The one in-memory copy of a private dictation that did not land.
///
/// A private dictation is never written to History, so when its paste fails
/// (nothing focused, target gone, or an unconfirmed paste) this is the only
/// way back to it besides the clipboard. It lives in memory only and ends at
/// whichever comes first: `lifetime`, the next dictation start, a Copy, or
/// quit. Swift strings cannot be reliably zeroed, so "wiped" means "dropped".
@MainActor
@Observable
public final class EphemeralDictation {
    public nonisolated static let defaultLifetime: TimeInterval = 120

    private var stored: String?
    public private(set) var expiresAt: Date?
    private let lifetime: TimeInterval
    private let now: @MainActor () -> Date
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    public init(
        lifetime: TimeInterval = EphemeralDictation.defaultLifetime,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.lifetime = lifetime
        self.now = now
    }

    /// The text, or nil once it has expired. Reading never mutates, so it is
    /// safe from a SwiftUI body; the expiry task does the actual drop.
    public var text: String? {
        guard let stored, let expiresAt, now() < expiresAt else { return nil }
        return stored
    }

    public var hasText: Bool { text != nil }

    public func set(_ text: String) {
        guard !text.isEmpty else { return }
        stored = text
        expiresAt = now().addingTimeInterval(lifetime)
        expiryTask?.cancel()
        let lifetime = lifetime
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            self?.wipe()
        }
    }

    /// Copies the text, marked concealed and transient, then drops it: Copy
    /// is one of the ways it expires.
    @discardableResult
    public func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text else {
            wipe()
            return false
        }
        ConcealedPasteboard.write(text, to: pasteboard, concealed: true)
        wipe()
        return true
    }

    public func wipe() {
        expiryTask?.cancel()
        expiryTask = nil
        stored = nil
        expiresAt = nil
    }
}

/// Plainsay's pasteboard write, optionally marked with the nspasteboard.org
/// conventions clipboard managers use to skip an item. Whether a given
/// manager honours them is outside Plainsay's control and unverified.
public enum ConcealedPasteboard {
    public static var concealedType: NSPasteboard.PasteboardType { .init("org.nspasteboard.ConcealedType") }
    public static var transientType: NSPasteboard.PasteboardType { .init("org.nspasteboard.TransientType") }

    @MainActor
    public static func write(_ text: String, to pasteboard: NSPasteboard, concealed: Bool) {
        pasteboard.clearContents()
        guard concealed else {
            pasteboard.setString(text, forType: .string)
            return
        }
        // One item carrying all three types, so a manager that inspects the
        // item sees the markers next to the text they describe.
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: concealedType)
        item.setString("", forType: transientType)
        pasteboard.writeObjects([item])
    }
}
