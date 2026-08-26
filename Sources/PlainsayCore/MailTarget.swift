import Foundation

/// Whether the app being dictated into is somewhere an email is written.
///
/// Dictating an email currently produces one unbroken block of text, which then
/// has to be reshaped by hand into a salutation, paragraphs and a sign-off —
/// exactly the work dictation was supposed to save. Knowing the target is a
/// mail composer is what lets cleanup produce that shape directly.
///
/// Detection is deliberately conservative. Reformatting text the speaker did
/// not want reformatted is worse than not offering the mode at all, so
/// everything here errs towards "not mail" and the user keeps a manual switch.
public enum MailTarget {
    /// Native clients, matched on bundle identifier.
    ///
    /// A dedicated mail app has no meaningful non-mail text field, so the
    /// bundle id alone is enough — unlike a browser, where most windows are
    /// not a compose box.
    static let mailAppBundleIdentifiers: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",       // Spark
        "it.bloop.airmail2",
        "org.mozilla.thunderbird",
        "eu.mailbird.mac",
        "com.postbox-inc.postbox",
        "com.CanaryMail.Mac",
        "com.superhuman.mail",
        "com.mimestream.Mimestream",
    ]

    /// Browsers, where the bundle id proves nothing on its own.
    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",       // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "ai.perplexity.comet",
    ]

    /// Title fragments that indicate a webmail *composer*, not merely a mailbox.
    ///
    /// Lowercased, and matched against the window title. The distinction
    /// matters: "Inbox (12) - Gmail" is someone reading their mail, and
    /// reformatting a reply-in-a-hurry there is unwanted. Only titles that say
    /// a message is being written count.
    static let composerTitleFragments = [
        "compose mail",     // Gmail's compose window, when popped out
        "new message",      // Gmail, Fastmail, Outlook Web
        "nowa wiadomość",
        "neue nachricht",
        "nouveau message",
        "nuevo mensaje",
        "verfassen",
    ]

    /// Webmail titles that only prove the *site* is mail, not that a message is
    /// open. Used together with a composer signal, never on their own.
    static let webmailTitleFragments = [
        "gmail", "outlook", "fastmail", "proton mail", "protonmail",
        "zoho mail", "yahoo mail", "roundcube", "poczta",
    ]

    /// Decides whether this target should be treated as an email composer.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: the app the text will be inserted into.
    ///   - windowTitle: its focused window title, when it could be read.
    ///     Nil is common and is not treated as evidence either way.
    public static func isComposer(bundleIdentifier: String?, windowTitle: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let id = bundleIdentifier.lowercased()

        if mailAppBundleIdentifiers.contains(where: { $0.lowercased() == id }) { return true }

        guard browserBundleIdentifiers.contains(where: { $0.lowercased() == id }) else { return false }

        // In a browser the title has to carry the whole argument, so it must
        // show both that this is webmail and that something is being written.
        guard let title = windowTitle?.lowercased(), !title.isEmpty else { return false }
        let looksLikeWebmail = webmailTitleFragments.contains { title.contains($0) }
        let looksLikeComposer = composerTitleFragments.contains { title.contains($0) }
        return looksLikeWebmail && looksLikeComposer
    }
}

/// How cleanup should shape the result.
public enum DictationStyle: String, Codable, Sendable, CaseIterable {
    /// Prose, as dictated. The default everywhere.
    case plain
    /// Email layout: salutation, paragraphs, sign-off, separated by blank lines.
    case email
}
