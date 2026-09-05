import AppKit
import ApplicationServices

/// Exact before/after matching identifies a paste without searching for similar
/// text elsewhere in the document. Unsupported editors simply get Copy instead.
@MainActor
public final class DictationInsertionAnchor: DictationReplacementTarget {
    public let replacedText: String
    private let app: NSRunningApplication
    private let element: AXUIElement
    private let window: AXUIElement
    private var range: NSRange
    private var document: String
    private var usable = true
    private var updatedAt = Date()
    private var confirmed = false

    private init(app: NSRunningApplication, element: AXUIElement, window: AXUIElement, range: NSRange, document: String) {
        self.app = app
        self.element = element
        self.window = window
        self.range = range
        self.document = document
        self.replacedText = (document as NSString).substring(with: range)
    }

    public static func capture() -> DictationInsertionAnchor? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = axElement(axApp, kAXFocusedUIElementAttribute),
              let window = axElement(axApp, kAXFocusedWindowAttribute),
              value(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole as String,
              let document = value(element, kAXValueAttribute) as? String, document.utf16.count <= 200_000,
              let range = selectedRange(element), checkedRange(range, in: document) != nil else { return nil }
        return DictationInsertionAnchor(app: app, element: element, window: window, range: range, document: document)
    }

    public func confirmInsertion(_ text: String) -> Bool {
        guard !confirmed, usable, focusMatches(),
              let expected = Self.replacing(document, range: range, with: text),
              Self.value(element, kAXValueAttribute) as? String == expected else { usable = false; return false }
        document = expected
        range.length = text.utf16.count
        confirmed = true
        return true
    }

    public func replace(with text: String) async throws {
        guard usable, confirmed, Date().timeIntervalSince(updatedAt) <= 300, !app.isTerminated,
              app.activate(options: []) else { throw DictationCorrectionError.stale }
        try await Task.sleep(for: .milliseconds(200))
        try Task.checkCancellation()
        guard focusMatches(), Self.value(element, kAXValueAttribute) as? String == document,
              let expected = Self.replacing(document, range: range, with: text) else {
            usable = false
            throw DictationCorrectionError.stale
        }
        var rangeSettable = DarwinBoolean(false), textSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable) == .success,
              AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &textSettable) == .success,
              rangeSettable.boolValue, textSettable.boolValue else { throw VoiceEditError.replacementUnsupported }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { throw DictationCorrectionError.stale }
        // A failed or unconfirmed write must never be retried against the old anchor.
        usable = false
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
              Self.selectedRange(element) == range,
              Self.value(element, kAXValueAttribute) as? String == document,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            throw VoiceEditError.replacementUnsupported
        }
        try await Task.sleep(for: .milliseconds(100))
        guard Self.value(element, kAXValueAttribute) as? String == expected else { throw DictationCorrectionError.unverified }
        document = expected
        range.length = text.utf16.count
        updatedAt = Date()
        usable = true
    }

    static func replacing(_ document: String, range: NSRange, with text: String) -> String? {
        guard let swiftRange = checkedRange(range, in: document) else { return nil }
        return document.replacingCharacters(in: swiftRange, with: text)
    }

    private static func checkedRange(_ range: NSRange, in document: String) -> Range<String.Index>? {
        guard let converted = Range(range, in: document), NSRange(converted, in: document) == range,
              (converted.lowerBound == document.endIndex || document.indices.contains(converted.lowerBound)),
              (converted.upperBound == document.endIndex || document.indices.contains(converted.upperBound)) else { return nil }
        return converted
    }

    private func focusMatches() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = Self.axElement(axApp, kAXFocusedUIElementAttribute), CFEqual(element, focused),
              let focusedWindow = Self.axElement(axApp, kAXFocusedWindowAttribute), CFEqual(window, focusedWindow) else { return false }
        return true
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var output: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &output) == .success else { return nil }
        return output
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return result as! AXUIElement
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        guard let result = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let ax = result as! AXValue
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
