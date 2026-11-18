import AppKit
import ApplicationServices

/// Reads Accessibility attributes of another application's focused window.
public enum FocusedWindow {
    /// The focused window title of `application`, or nil when it cannot be read.
    /// Webmail detection uses the title to distinguish a compose window from
    /// other windows in the same browser.
    public static func title(of application: NSRunningApplication) -> String? {
        guard let window = element(of: application) else { return nil }

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef
        ) == .success else { return nil }

        return titleRef as? String
    }

    /// The focused window frame in global Accessibility coordinates, if available.
    public static func accessibilityFrame(of application: NSRunningApplication) -> CGRect? {
        guard let window = element(of: application),
              let position = value(kAXPositionAttribute, of: window),
              let size = value(kAXSizeAttribute, of: window)
        else { return nil }

        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite,
              dimensions.width.isFinite, dimensions.width > 0,
              dimensions.height.isFinite, dimensions.height > 0
        else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func element(of application: NSRunningApplication) -> AXUIElement? {
        // Use the non-prompting check so the dictation target keeps focus.
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return (window as! AXUIElement)
    }

    private static func value(_ attribute: String, of window: AXUIElement) -> AXValue? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &valueRef) == .success,
              let value = valueRef, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
