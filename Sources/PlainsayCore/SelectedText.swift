import AppKit
import ApplicationServices

/// Captures only an explicit selection. No clipboard scraping or simulated Copy.
@MainActor
public final class SelectedText {
    public let text: String
    private let application: NSRunningApplication
    private let element: AXUIElement
    private let window: AXUIElement?
    private let range: CFRange
    private let document: String?

    private init(text: String, application: NSRunningApplication, element: AXUIElement,
                 window: AXUIElement?, range: CFRange, document: String?) {
        self.text = text
        self.application = application
        self.element = element
        self.window = window
        self.range = range
        self.document = document
    }

    public static func capture() throws -> SelectedText {
        guard AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw VoiceEditError.emptySelection
        }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        guard let element = elementValue(app, kAXFocusedUIElementAttribute),
              value(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole as String,
              let text = value(element, kAXSelectedTextAttribute) as? String, !text.isEmpty,
              let range = selectionRange(element) else { throw VoiceEditError.emptySelection }
        guard text.count <= 12_000 else { throw VoiceEditError.tooLong }
        return SelectedText(text: text, application: application, element: element,
            window: elementValue(app, kAXFocusedWindowAttribute), range: range,
            document: value(element, kAXValueAttribute) as? String)
    }

    /// Set the selection directly only when its identity and contents still match.
    /// Apps with incomplete Accessibility support retain the manual Copy path.
    public func replace(with replacement: String) async throws {
        guard !application.isTerminated else { throw VoiceEditError.selectionChanged }
        guard application.activate(options: []) else { throw VoiceEditError.selectionChanged }
        try await Task.sleep(for: .milliseconds(200))
        try Task.checkCancellation()
        let app = AXUIElementCreateApplication(application.processIdentifier)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let focused = Self.elementValue(app, kAXFocusedUIElementAttribute), CFEqual(focused, element),
              let currentRange = Self.selectionRange(element),
              Self.matches(original: text, range: range, document: document,
                           current: Self.value(element, kAXSelectedTextAttribute) as? String,
                           currentRange: currentRange, currentDocument: Self.value(element, kAXValueAttribute) as? String)
        else { throw VoiceEditError.selectionChanged }
        if let window {
            guard let current = Self.elementValue(app, kAXFocusedWindowAttribute), CFEqual(window, current) else {
                throw VoiceEditError.selectionChanged
            }
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { throw VoiceEditError.replacementUnsupported }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
            sanitizeForInsertion(replacement) as CFString) == .success else { throw VoiceEditError.replacementUnsupported }
    }

    static func matches(original: String, range: CFRange, document: String?,
                        current: String?, currentRange: CFRange, currentDocument: String?) -> Bool {
        original == current && range.location == currentRange.location && range.length == currentRange.length
            && (document == nil || document == currentDocument)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func selectionRange(_ element: AXUIElement) -> CFRange? {
        guard let value = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range) else { return nil }
        return range
    }
}
