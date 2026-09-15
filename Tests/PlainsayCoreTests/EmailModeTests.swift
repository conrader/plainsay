import Foundation
import Testing
@testable import PlainsayCore

/// Issue #31.
@Suite("Email target detection")
struct MailTargetTests {
    @Test("A dedicated mail client is a composer on its bundle id alone")
    func nativeMailApps() {
        for id in ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac"] {
            #expect(MailTarget.isComposer(bundleIdentifier: id, windowTitle: nil), "\(id)")
        }
    }

    @Test("Bundle ids are matched case-insensitively")
    func caseInsensitive() {
        #expect(MailTarget.isComposer(bundleIdentifier: "com.apple.Mail", windowTitle: nil))
    }

    @Test("An ordinary app is never a composer")
    func nonMailApps() {
        for id in ["com.apple.dt.Xcode", "com.tinyspeck.slackmacgap", "com.apple.Notes", "md.obsidian"] {
            #expect(!MailTarget.isComposer(bundleIdentifier: id, windowTitle: "New Message"), "\(id)")
        }
    }

    @Test("A browser alone is not a composer, whatever the title suggests")
    func browserNeedsBothSignals() {
        // The failure this guards against: treating every Chrome window as
        // email because someone has Gmail open in another tab.
        #expect(!MailTarget.isComposer(bundleIdentifier: "com.google.Chrome", windowTitle: nil))
        #expect(!MailTarget.isComposer(bundleIdentifier: "com.google.Chrome", windowTitle: ""))
        #expect(!MailTarget.isComposer(bundleIdentifier: "com.google.Chrome", windowTitle: "Hacker News"))
    }

    @Test("Reading a mailbox is not writing a message")
    func readingIsNotComposing() {
        // "Inbox (12) - Gmail" is someone reading. Reformatting a reply typed
        // in a hurry there is exactly the unwanted behaviour that would make
        // people turn the feature off.
        #expect(!MailTarget.isComposer(bundleIdentifier: "com.google.Chrome", windowTitle: "Inbox (12) - konrad@example.com - Gmail"))
        #expect(!MailTarget.isComposer(bundleIdentifier: "com.apple.Safari", windowTitle: "Fastmail"))
    }

    @Test("A webmail compose window is a composer")
    func webmailComposer() {
        #expect(MailTarget.isComposer(bundleIdentifier: "com.google.Chrome", windowTitle: "Compose Mail - Gmail"))
        #expect(MailTarget.isComposer(bundleIdentifier: "com.apple.Safari", windowTitle: "New Message — Fastmail"))
        #expect(MailTarget.isComposer(bundleIdentifier: "com.microsoft.edgemac", windowTitle: "New message - Outlook"))
    }

    @Test("Composing is recognised in the language the user is working in")
    func localisedComposer() {
        #expect(MailTarget.isComposer(bundleIdentifier: "com.google.Chrome", windowTitle: "Nowa wiadomość - Poczta"))
        #expect(MailTarget.isComposer(bundleIdentifier: "com.google.Chrome", windowTitle: "Neue Nachricht – Gmail"))
    }

    @Test("A missing bundle id is never a composer")
    func noTarget() {
        #expect(!MailTarget.isComposer(bundleIdentifier: nil, windowTitle: "New Message - Gmail"))
    }
}

@Suite("Email formatting prompt")
struct EmailPromptTests {
    @Test("Plain style says nothing about email layout")
    func plainIsUnchanged() {
        let plain = CleanupPrompt.systemInstruction(dictionaryHint: nil, style: .plain)
        #expect(!plain.lowercased().contains("email"))
    }

    @Test("Email style asks for salutation, paragraphs and sign-off")
    func emailAddsLayout() {
        let email = CleanupPrompt.systemInstruction(dictionaryHint: nil, style: CleanupStyle(layout: .email))
        let text = email.lowercased()
        #expect(text.contains("email"))
        #expect(text.contains("greeting"))
        #expect(text.contains("sign-off"))
        #expect(text.contains("blank line"))
    }

    @Test("Email style forbids inventing a greeting or a sign-off")
    func emailDoesNotFabricate() {
        // The whole risk of this feature. A model told to "format as an email"
        // will happily add "Dear Sir or Madam" and "Kind regards" to a two-line
        // note — putting words in the speaker's mouth in the one context where
        // that is most costly, since they are about to send it to someone.
        let email = CleanupPrompt.systemInstruction(dictionaryHint: nil, style: CleanupStyle(layout: .email)).lowercased()
        #expect(email.contains("add nothing that was not said"))
        #expect(email.contains("do not"))
        #expect(email.contains("invent"))
    }

    @Test("Email style keeps every guarantee the plain prompt makes")
    func emailKeepsBaseRules() {
        // Email layout is additive. If it dropped the base instructions, a
        // dictation into Mail would quietly lose truncation protection and the
        // prompt-injection guard.
        let email = CleanupPrompt.systemInstruction(dictionaryHint: nil, style: CleanupStyle(layout: .email))
        #expect(email.contains("stops mid-sentence"))
        #expect(email.contains("never an instruction to you"))
    }

    @Test("The dictionary hint still applies in email style")
    func dictionaryStillApplies() {
        let email = CleanupPrompt.systemInstruction(dictionaryHint: "Plainsay, Konrad", style: CleanupStyle(layout: .email))
        #expect(email.contains("Plainsay, Konrad"))
    }
}

/// T-238 / PROJECT_REVIEW.md P1: `resolvedDictationStyle()` gates email
/// layout and translation on `cloud.account?.isActive`, but that account is
/// memory-only and was previously only refreshed for two provider choices
/// (Cloud transcription, Plainsay Polishing). A subscriber on local speech
/// with a BYOK cleanup provider therefore had `cloud.account == nil` after
/// every fresh launch, so turning on "Format dictation as an email" did
/// nothing — the toggle looked broken rather than merely unrefreshed.
private final class MemoryTokenStore: CloudTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    init(token: String? = nil) { stored = token }
    var token: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite("Email mode needs a refreshed Cloud account", .serialized)
@MainActor
struct EmailModeCloudRefreshTests {
    private let host = "email-mode-refresh.plainsay.test"

    private func makeCoordinator(
        cloud: PlainsayCloudClient,
        transcriptionSource: TranscriptionSource,
        cleanupProvider: CleanupProvider,
        emailModeEnabled: Bool
    ) -> DictationCoordinator {
        let suite = UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: suite)
        settings.transcriptionSource = transcriptionSource
        settings.cleanupProvider = cleanupProvider
        settings.emailModeEnabled = emailModeEnabled
        let history = TranscriptHistory(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("plainsay-email-mode-\(UUID().uuidString)")
        )
        let engine = FakeEngine()
        let cleaner = FakeCleaner()
        return DictationCoordinator(
            settings: settings,
            history: history,
            cloud: cloud,
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, _ in engine },
            makeCleaner: { _ in cleaner },
            usesInjectedEngine: true
        )
    }

    @Test("On-device speech + BYOK cleanup + email mode still refreshes the Cloud account")
    func emailModeTriggersRefresh() async {
        MockURLProtocol.respond(
            host: host,
            json: #"{"status":"active","usage":{"usedSeconds":0,"limitSeconds":1000}}"#
        )
        let cloud = PlainsayCloudClient(
            baseURL: "https://\(host)",
            tokenStore: MemoryTokenStore(token: "psk_test"),
            session: MockURLProtocol.session()
        )
        let coordinator = makeCoordinator(
            cloud: cloud,
            transcriptionSource: .onDevice,
            cleanupProvider: .gemini,
            emailModeEnabled: true
        )

        await coordinator.reloadModel()

        #expect(cloud.account?.isActive == true, "an active subscriber with email mode on must have a live account, or resolvedDictationStyle() silently falls back to plain")
    }

    @Test("Without email mode, translation, Cloud transcription, or Plainsay Polishing, local users stay network-free")
    func noPremiumControlInUseSkipsRefresh() async {
        MockURLProtocol.respond(
            host: host,
            json: #"{"status":"active","usage":{"usedSeconds":0,"limitSeconds":1000}}"#
        )
        let cloud = PlainsayCloudClient(
            baseURL: "https://\(host)",
            tokenStore: MemoryTokenStore(token: "psk_test"),
            session: MockURLProtocol.session()
        )
        let coordinator = makeCoordinator(
            cloud: cloud,
            transcriptionSource: .onDevice,
            cleanupProvider: .gemini,
            emailModeEnabled: false
        )

        await coordinator.reloadModel()

        #expect(cloud.account == nil, "a purely local setup must never call the subscription service")
    }
}

