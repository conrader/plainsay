import AppKit
import Foundation
import Testing
@testable import PlainsayCore

// Pipeline tests for app profiles (spec-appprofiles-xreview/SPEC.fixed.md §4,
// tests 7–11, 13–14 and the pipeline halves of 9b–9d). Same fakes as
// PipelineTests; the frontmost app and the webmail window title are injected
// through the new `captureTargetBundleIdentifier` / `readTargetWindowTitle`
// seams, so nothing reads the machine's real frontmost app.
// Test 6 (zero profiles) is the existing PipelineTests / EmailModeTests /
// TranslationTests / PrivateDictationTests suites, unchanged.

@MainActor
final class FrontmostBox {
    var bundleIdentifier: String? = "com.example.editor"
    var windowTitle: String?
    var captures = 0
}

/// Answers `/v1/me` as an active subscriber and counts the calls per host.
final class CountingCloudProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func count(_ host: String) -> Int { lock.withLock { counts[host] ?? 0 } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingCloudProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host() ?? ""
        Self.lock.withLock { Self.counts[host, default: 0] += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"active","usage":{"usedSeconds":0,"limitSeconds":1000}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class ProfileTokenStore: CloudTokenStoring, @unchecked Sendable {
    var token: String?
    init(token: String? = nil) { self.token = token }
}

@MainActor
private struct ProfileHarness {
    let settings: PlainsaySettings
    let recorder = FakeRecorder()
    let engine = FakeEngine()
    let cleaner = FakeCleaner()
    let cleanerBuilds = CaptureCount()
    let inserter = FakeInserter()
    let pasteTarget = FakePasteTarget()
    let frontmost = FrontmostBox()
    let history: TranscriptHistory
    let cloud: PlainsayCloudClient
    let host: String
    let coordinator: DictationCoordinator

    /// `signedIn` makes the Cloud client answer as an active subscriber (no
    /// network: `CountingCloudProtocol`). Otherwise it is unsigned and unreachable.
    init(signedIn: Bool = false, profiles: [DictationProfile] = [], terms: [String] = ["Plainsay"]) {
        let suite = UserDefaults(suiteName: "plainsay.profile.pipeline.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: suite)
        settings.dictionary = TermDictionary(terms: terms)
        settings.playFeedbackSounds = false
        settings.transcriptionSource = .onDevice
        settings.cleanupProvider = .gemini
        settings.appProfiles = profiles
        self.settings = settings
        history = TranscriptHistory(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("plainsay-profiles-\(UUID().uuidString)")
        )
        host = "profiles-\(UUID().uuidString.prefix(8).lowercased()).plainsay.test"
        cloud = PlainsayCloudClient(
            baseURL: "https://\(host)",
            tokenStore: ProfileTokenStore(token: signedIn ? "psk_test" : nil),
            session: CountingCloudProtocol.session()
        )
        let engine = self.engine
        let cleaner = self.cleaner
        let builds = cleanerBuilds
        let pasteTarget = self.pasteTarget
        let frontmost = self.frontmost
        coordinator = DictationCoordinator(
            settings: settings,
            history: history,
            cloud: cloud,
            recorder: recorder,
            inserter: inserter,
            makeEngine: { _, _, _ in engine },
            makeCleaner: { _ in
                builds.value += 1
                return cleaner
            },
            microphoneAuthorized: { true },
            capturePasteTarget: { pasteTarget },
            captureTargetBundleIdentifier: {
                frontmost.captures += 1
                return frontmost.bundleIdentifier
            },
            readTargetWindowTitle: { frontmost.windowTitle },
            usesInjectedEngine: true
        )
    }

    var refreshCount: Int { CountingCloudProtocol.count(host) }

    func ready() async { await coordinator.reloadModel() }

    func dictate(in bundleIdentifier: String?) {
        frontmost.bundleIdentifier = bundleIdentifier
        coordinator.handleHotkeyEdge(.down(at: 0))
        coordinator.handleHotkeyEdge(.up(at: 1))
    }

    /// Settled: not recording, not busy, and the work unit ended (the policy
    /// is back to `.standard` exactly then).
    func settle(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !recorder.isRecording, !coordinator.phase.isBusy, coordinator.sessionPolicy == .standard,
               inserter.handledAnything {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private let vscode = "com.microsoft.VSCode"
/// Localized like the app, so the suite passes on a Polish or German Mac.
private var localOnly: String { DictationProfileRoute.label(source: .onDevice, polishing: false, provider: .gemini) }
private var noTranslation: String { Localization.coreString("hud.profile.noTranslation", fallback: "no translation") }

@Suite("App profiles in the pipeline", .serialized)
@MainActor
struct ProfilePipelineTests {
    @Test("7. Polishing Off for VS Code: the cleaner is never built and the text is corrected raw; other apps still polish")
    func polishingOff() async throws {
        let code = DictationProfile(name: "Code", bundleIdentifiers: [vscode], extraTerms: ["kubectl"], polishing: .off)
        let harness = ProfileHarness(profiles: [code])
        harness.engine.transcript = "run cube control get pods"
        await harness.ready()

        harness.dictate(in: "com.microsoft.vscode")
        try await harness.settle()
        #expect(harness.cleanerBuilds.value == 0)
        #expect(harness.cleaner.received == nil)
        let policyDictionary = TermDictionary(terms: ["kubectl", "Plainsay"])
        let expected = sanitizeForInsertion(policyDictionary.applyCorrections(to: normalizeTranscript("run cube control get pods")))
        #expect(harness.inserter.inserted == [expected])
        #expect(harness.engine.receivedPrompt?.contains("kubectl") == true)

        harness.dictate(in: "com.apple.Notes")
        try await harness.settle()
        #expect(harness.cleanerBuilds.value == 1)
        #expect(harness.inserter.inserted.last == harness.cleaner.output)
        #expect(harness.engine.receivedPrompt?.contains("kubectl") == false)
    }

    @Test("8. Snapshot: settings changed while recording apply from the next dictation")
    func snapshot() async throws {
        let code = DictationProfile(name: "Code", bundleIdentifiers: [vscode])
        let harness = ProfileHarness(profiles: [code], terms: ["Alpha"])
        await harness.ready()

        harness.frontmost.bundleIdentifier = vscode
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.sessionPolicy.profileName == "Code")
        // Mid-recording edits, including what the translation chord changes.
        harness.settings.dictionary = TermDictionary(terms: ["Bravo"])
        harness.settings.translationTargetLanguage = "pl"
        harness.settings.emailModeEnabled = true
        harness.frontmost.bundleIdentifier = "com.apple.Notes" // switching apps does not re-resolve
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()

        #expect(harness.engine.receivedPrompt?.contains("Alpha") == true)
        #expect(harness.engine.receivedPrompt?.contains("Bravo") == false)
        #expect(harness.frontmost.captures == 1)

        harness.dictate(in: vscode)
        try await harness.settle()
        #expect(harness.engine.receivedPrompt?.contains("Bravo") == true)
    }

    @Test("9. No active account: a profile's translation and email are not applied; Polishing still runs for BYOK")
    func entitlementGateHolds() async throws {
        let mail = DictationProfile(name: "Mail", bundleIdentifiers: ["com.apple.mail"], emailLayout: .composers, translation: .target("pl"))
        let harness = ProfileHarness(profiles: [mail])
        await harness.ready()
        harness.dictate(in: "com.apple.mail")
        try await harness.settle()

        #expect(harness.coordinator.cloud.account == nil)
        #expect(harness.cleanerBuilds.value == 1)
        #expect(harness.cleaner.receivedStyle == .plain)
    }

    @Test("9. Active account: translation applies, and email layout applies in a mail composer (layout seam)")
    func entitledProfile() async throws {
        let mail = DictationProfile(name: "Mail", bundleIdentifiers: ["com.apple.mail", "com.google.Chrome"],
                                    emailLayout: .composers, translation: .target("pl"))
        let harness = ProfileHarness(signedIn: true, profiles: [mail])
        await harness.ready()
        #expect(harness.coordinator.cloud.account?.isActive == true)

        harness.dictate(in: "com.apple.mail")
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle == CleanupStyle(layout: .email, translateTo: "pl"))

        // A browser needs the (injected) window title to count as a composer.
        harness.frontmost.windowTitle = "New Message - Gmail"
        harness.dictate(in: "com.google.Chrome")
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle == CleanupStyle(layout: .email, translateTo: "pl"))

        harness.frontmost.windowTitle = "Inbox - Gmail"
        harness.dictate(in: "com.google.Chrome")
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle == CleanupStyle(layout: .plain, translateTo: "pl"))
    }

    @Test("remember-correction 20a. With translation, replacement rules apply to the translated output")
    func rulesAfterTranslation() async throws {
        let mail = DictationProfile(name: "Mail", bundleIdentifiers: ["com.apple.mail"], translation: .target("pl"))
        let harness = ProfileHarness(signedIn: true, profiles: [mail])
        harness.settings.replacementRules = ReplacementRuleSet(rules: [ReplacementRule(from: "jason", to: "JSON")])
        harness.engine.transcript = "open the jason file"
        harness.cleaner.output = "Otwórz plik jason."
        await harness.ready()

        harness.dictate(in: "com.apple.mail")
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle?.translateTo == "pl")
        #expect(harness.cleaner.received == "open the jason file")
        #expect(harness.inserter.inserted.last == "Otwórz plik JSON.")
    }

    @Test("9b. A hand-edited Polishing Off + translation profile builds no cleaner and pastes plain text")
    func polishingOffBeatsTranslation() async throws {
        let stored = DictationProfile(name: "Odd", bundleIdentifiers: [vscode], polishing: .off, translation: .target("pl"))
        let harness = ProfileHarness(signedIn: true, profiles: [stored])
        await harness.ready()
        harness.frontmost.bundleIdentifier = vscode
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Odd · \(localOnly)")
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.cleanerBuilds.value == 0)
        #expect(harness.coordinator.profileChip == nil)
    }

    @Test("9c. Editing a profile to request translation refreshes the account once; unsigned users never call out")
    func refreshOnEdit() async throws {
        let harness = ProfileHarness(signedIn: true, profiles: [DictationProfile(name: "Notes", bundleIdentifiers: ["com.apple.Notes"])])
        await harness.ready()
        #expect(harness.refreshCount == 0, "nothing needs Cloud yet: stay network-free")
        #expect(harness.coordinator.cloud.account == nil)

        harness.settings.appProfiles[0].translation = .target("pl")
        await harness.coordinator.appProfilesChanged()
        #expect(harness.refreshCount == 1)
        #expect(harness.coordinator.cloud.account?.isActive == true)

        let unsigned = ProfileHarness(profiles: [DictationProfile(name: "Notes", bundleIdentifiers: ["com.apple.Notes"])])
        await unsigned.ready()
        unsigned.settings.appProfiles[0].translation = .target("pl")
        await unsigned.coordinator.appProfilesChanged()
        #expect(unsigned.refreshCount == 0)
        #expect(unsigned.coordinator.cloud.account == nil)
    }

    @Test("10. A profile that needs Cloud makes model load refresh the account; none needing it stays network-free")
    func refreshOnLoad() async {
        let translate = DictationProfile(name: "T", bundleIdentifiers: ["a.b"], translation: .target("pl"))
        let needs = ProfileHarness(signedIn: true, profiles: [translate])
        await needs.ready()
        #expect(needs.refreshCount == 1)
        #expect(needs.coordinator.cloud.account?.isActive == true)

        let quiet = ProfileHarness(signedIn: true, profiles: [DictationProfile(name: "Q", bundleIdentifiers: ["a.b"], output: .copyOnly)])
        await quiet.ready()
        #expect(quiet.refreshCount == 0)
        #expect(quiet.coordinator.cloud.account == nil)
    }

    @Test("9d. The chord in an app whose profile turns translation off: global toggles, this app is not translated")
    func chordInProfiledApp() async throws {
        let code = DictationProfile(name: "Code", bundleIdentifiers: [vscode], translation: .off)
        let harness = ProfileHarness(signedIn: true, profiles: [code])
        await harness.ready()
        // Become an entitled subscriber with "de" as the last target, then
        // switch translation off globally so the chord turns it back on.
        harness.settings.translationTargetLanguage = "de"
        await harness.coordinator.refreshCloudCleanupIfNeeded()
        #expect(harness.coordinator.cloud.account?.isActive == true)
        harness.settings.translationTargetLanguage = nil

        harness.coordinator.toggleTranslation()
        #expect(harness.settings.translationTargetLanguage == "de")
        harness.frontmost.bundleIdentifier = vscode
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip?.hasPrefix("Code · ") == true)
        #expect(harness.coordinator.profileChip?.hasSuffix(" · " + noTranslation) == true)
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle?.translateTo == nil)

        harness.dictate(in: "com.apple.Notes")
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle?.translateTo == "de")
    }

    @Test("11. Copy only: clipboard, no paste, no reacquire, acknowledged History, phase .copied")
    func copyOnly() async throws {
        let term = DictationProfile(name: "Terminal", bundleIdentifiers: ["com.apple.Terminal"], output: .copyOnly)
        let harness = ProfileHarness(profiles: [term])
        await harness.ready()
        harness.dictate(in: "com.apple.Terminal")
        try await harness.settle()

        #expect(harness.inserter.copied == [harness.cleaner.output])
        #expect(harness.inserter.inserted.isEmpty)
        #expect(harness.pasteTarget.reacquireCount == 0)
        #expect(harness.history.records.first?.outcome == .insertionUnverifiedAcknowledged)
        #expect(harness.history.hasUnacknowledgedInsertion == false)
        #expect(harness.coordinator.phase == .copied)
        #expect(!harness.coordinator.phase.isBusy)
        #expect(harness.coordinator.lastDictation?.text == harness.cleaner.output)
    }

    @Test("13. A refused or failed start creates no session and leaves nothing behind")
    func refusedStart() async throws {
        let code = DictationProfile(name: "Code", bundleIdentifiers: [vscode], polishing: .off)
        let harness = ProfileHarness(profiles: [code])
        await harness.ready()
        harness.recorder.startError = CocoaError(.fileNoSuchFile)
        harness.dictate(in: vscode)
        #expect(harness.coordinator.sessionPolicy == .standard)
        #expect(harness.coordinator.targetBundleIdentifier == nil)
        #expect(harness.coordinator.profileChip == nil)

        harness.recorder.startError = nil
        try await Task.sleep(for: .milliseconds(50))
        harness.dictate(in: "com.apple.Notes")
        try await harness.settle()
        #expect(harness.cleanerBuilds.value == 1, "the next dictation resolves fresh to Default")
    }

    @Test("14. Escape clears the session; the next dictation in another app resolves fresh")
    func cancelClears() async throws {
        let code = DictationProfile(name: "Code", bundleIdentifiers: [vscode], polishing: .off)
        let harness = ProfileHarness(profiles: [code])
        await harness.ready()
        harness.frontmost.bundleIdentifier = vscode
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(localOnly)")
        #expect(harness.coordinator.cancelDictation())
        #expect(harness.coordinator.sessionPolicy == .standard)
        #expect(harness.coordinator.profileChip == nil)

        try await Task.sleep(for: .milliseconds(50))
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        harness.dictate(in: "com.apple.Notes")
        try await harness.settle()
        #expect(harness.cleanerBuilds.value == 1)
    }

    @Test("Default shows no chip, so the HUD is unchanged without profiles")
    func noChipForDefault() async throws {
        let harness = ProfileHarness()
        await harness.ready()
        harness.frontmost.bundleIdentifier = vscode
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.phase == .recording)
        #expect(harness.coordinator.profileChip == nil)
        #expect(harness.coordinator.sessionPolicy.profileID == nil)
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
    }

    @Test("A private dictation ignores the profile's Copy only and Polishing, keeps its vocabulary, and shows no chip")
    func privateBeatsProfile() async throws {
        let code = DictationProfile(name: "Code", bundleIdentifiers: [vscode], extraTerms: ["kubectl"], output: .copyOnly)
        let harness = ProfileHarness(profiles: [code])
        await harness.ready()
        #expect(harness.coordinator.armPrivateNextDictation() == nil)
        harness.frontmost.bundleIdentifier = vscode
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == nil)
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.inserter.inserted.count == 1)
        #expect(harness.inserter.copied.isEmpty)
        #expect(harness.cleanerBuilds.value == 0)
        #expect(harness.engine.receivedPrompt?.contains("kubectl") == true)
    }

    @Test("Chip route labels: local only, Polishing provider, remote, Cloud — all distinct")
    func routeLabels() {
        let labels = [
            DictationProfileRoute.label(source: .onDevice, polishing: false, provider: .gemini),
            DictationProfileRoute.label(source: .onDevice, polishing: true, provider: .gemini),
            DictationProfileRoute.label(source: .cloud, polishing: true, provider: .plainsay),
            DictationProfileRoute.label(source: .remote, polishing: false, provider: .gemini),
        ]
        #expect(Set(labels).count == 4 && labels.allSatisfy { !$0.isEmpty })
        #expect(labels[1].contains(CleanupProvider.gemini.displayName))
    }

    @Test("The Copy-only log line names no profile and can redact the app")
    func copyOnlyLog() {
        let line = PasteDecisionLog.copyOnlyMessage(targetBundleIdentifier: "com.apple.Terminal")
        #expect(line.contains("output=copy-only") && line.contains("target=com.apple.Terminal"))
        #expect(PasteDecisionLog.copyOnlyMessage(targetBundleIdentifier: nil).contains("target=redacted"))
    }
}
