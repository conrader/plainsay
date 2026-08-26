import AppKit
import ApplicationServices

/// Reads the title of the frontmost window of another application.
///
/// Needed only for webmail: a browser's bundle identifier says nothing about
/// whether the tab in front is a compose box or a news site, so the title has
/// to carry that argument. Native mail clients are matched on bundle id alone
/// and never reach this.
public enum FocusedWindow {
    /// The focused window title of `application`, or nil when it cannot be read.
    ///
    /// Nil is an ordinary outcome, not an error: Accessibility may not be
    /// granted, the app may expose no focused window, and some apps simply do
    /// not publish a title. Callers treat nil as "no evidence" rather than as
    /// "not mail", because guessing in either direction from a failed read is
    /// worse than declining to guess.
    public static func title(of application: NSRunningApplication) -> String? {
        // Asking an app that has not granted us Accessibility returns an error
        // rather than prompting, which is what we want here — a dictation is in
        // flight and a permission dialog would steal the focus we are about to
        // paste into.
        guard AXIsProcessTrusted() else { return nil }

        let app = AXUIElementCreateApplication(application.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef
        else { return nil }

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef
        ) == .success else { return nil }

        return titleRef as? String
    }
}
