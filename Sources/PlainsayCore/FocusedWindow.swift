import AppKit
import ApplicationServices

/// Reads Accessibility attributes of another application's focused window.
///
/// The title is needed only for webmail: a browser's bundle identifier says
/// nothing about whether the tab in front is a compose box or a news site, so
/// the title has to carry that argument. Native mail clients are matched on
/// bundle id alone and never reach this.
public enum FocusedWindow {
    /// The focused window title of `application`, or nil when it cannot be read.
    ///
    /// Nil is an ordinary outcome, not an error: Accessibility may not be
    /// granted, the app may expose no focused window, and some apps simply do
    /// not publish a title. Callers treat nil as "no evidence" rather than as
    /// "not mail", because guessing in either direction from a failed read is
    /// worse than declining to guess.
    public static func title(of application: NSRunningApplication) -> String? {
        guard let window = element(of: application) else { return nil }

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef
        ) == .success else { return nil }

        return titleRef as? String
    }

    /// The focused window frame in global Accessibility coordinates, if available.
    ///
    /// A non-nil `messagingTimeout` bounds each Accessibility request, so a
    /// hung target app yields nil quickly instead of blocking the caller for
    /// the system default (several seconds).
    public static func accessibilityFrame(
        of application: NSRunningApplication, messagingTimeout: Float? = nil
    ) -> CGRect? {
        guard let window = element(of: application, messagingTimeout: messagingTimeout),
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

    private static func element(
        of application: NSRunningApplication, messagingTimeout: Float? = nil
    ) -> AXUIElement? {
        // Asking an app that has not granted us Accessibility returns an error
        // rather than prompting, which is what we want here — a dictation is in
        // flight and a permission dialog would steal the focus we are about to
        // paste into.
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        if let messagingTimeout { AXUIElementSetMessagingTimeout(app, messagingTimeout) }
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowValue = windowRef, CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowValue as! AXUIElement
        if let messagingTimeout { AXUIElementSetMessagingTimeout(window, messagingTimeout) }
        return window
    }

    private static func value(_ attribute: String, of window: AXUIElement) -> AXValue? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &valueRef) == .success,
              let value = valueRef, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
