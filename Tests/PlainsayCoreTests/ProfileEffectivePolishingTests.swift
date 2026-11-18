import Foundation
import Testing
@testable import PlainsayCore

// App profiles review fixes (appprofiles-fix-job/REVIEW-sol.md 1–2): the
// editor and the HUD chip follow the Polishing that will actually run (one
// `PolishingReadiness` rule with `ProviderFactory.makeCleaner`).
// Keys come from `cleanupKeyLookup`, never the login Keychain.

@Suite("Effective Polishing for app profiles", .serialized)
@MainActor
struct ProfileEffectivePolishingTests {
    private let code = "com.microsoft.VSCode"
    private let raw = "um so the thing is uh it works"

    private var translatesToPolish: DictationProfile {
        DictationProfile(name: "Code", bundleIdentifiers: [code], translation: .target("pl"))
    }

    private var localOnly: String { DictationProfileRoute.label(source: .onDevice, polishing: false, provider: .gemini) }
    private var geminiPolishing: String { DictationProfileRoute.label(source: .onDevice, polishing: true, provider: .gemini) }
    private var noTranslation: String { Localization.coreString("hud.profile.noTranslation", fallback: "no translation") }

    private func settings(key: String, enabled: Bool = true, provider: CleanupProvider = .gemini) -> PlainsaySettings {
        let settings = PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!)
        settings.cleanupEnabled = enabled
        settings.cleanupProvider = provider
        settings.cleanupKeyLookup = { _ in key }
        return settings
    }

    // MARK: Finding 1 — what the editor may offer

    @Test("Readiness: off and a missing key offer no email/translation; an unrefreshed subscription still does")
    func readinessRule() {
        let off = ProviderFactory.polishingReadiness(cleanupEnabled: false, provider: .gemini, hasKey: true, cloudSessionToken: "t")
        #expect(off == .off && !off.runs && !off.offersStyles)
        let noKey = ProviderFactory.polishingReadiness(cleanupEnabled: true, provider: .gemini, hasKey: false, cloudSessionToken: "t")
        #expect(noKey == .missingKey(.gemini) && !noKey.runs && !noKey.offersStyles)
        let keyed = ProviderFactory.polishingReadiness(cleanupEnabled: true, provider: .anthropic, hasKey: true, cloudSessionToken: nil)
        #expect(keyed == .ready && keyed.runs && keyed.offersStyles)
        let unrefreshed = ProviderFactory.polishingReadiness(cleanupEnabled: true, provider: .plainsay, hasKey: false, cloudSessionToken: nil)
        #expect(unrefreshed == .needsSubscription && !unrefreshed.runs && unrefreshed.offersStyles)
        let subscribed = ProviderFactory.polishingReadiness(cleanupEnabled: true, provider: .plainsay, hasKey: false, cloudSessionToken: "t")
        #expect(subscribed == .ready)
    }

    @Test("Real factory: BYOK without its key and an active subscription builds NoCleanup, and the editor offers no styles")
    func realFactoryMissingKey() {
        ProviderFactory.cloudSessionToken = "psk_test"
        defer { ProviderFactory.cloudSessionToken = nil }

        let missing = settings(key: "")
        #expect(ProviderFactory.makeCleaner(missing) is NoCleanup)
        #expect(ProviderFactory.polishingReadiness(missing) == .missingKey(.gemini))
        #expect(!ProviderFactory.polishingReadiness(missing).offersStyles)

        let globalOff = settings(key: "k", enabled: false)
        #expect(ProviderFactory.makeCleaner(globalOff) is NoCleanup)
        #expect(!ProviderFactory.polishingReadiness(globalOff).offersStyles)

        let keyed = settings(key: "k")
        #expect(ProviderFactory.makeCleaner(keyed) is GeminiCleanupService)
        #expect(ProviderFactory.polishingReadiness(keyed) == .ready)
    }

    @Test("Real factory: Plainsay without a session token builds NoCleanup but keeps the subscription choices offered")
    func realFactoryUnrefreshedSubscription() {
        ProviderFactory.cloudSessionToken = nil
        let plainsay = settings(key: "", provider: .plainsay)
        #expect(ProviderFactory.makeCleaner(plainsay) is NoCleanup)
        #expect(ProviderFactory.polishingReadiness(plainsay) == .needsSubscription)
        #expect(ProviderFactory.polishingReadiness(plainsay).offersStyles)
    }

    // MARK: Finding 2 — the HUD chip states what runs

    @Test("Chip: missing BYOK key + active subscription + profile → PL says Local only · no translation, and text stays raw")
    func chipMissingKey() async throws {
        defer { ProviderFactory.cloudSessionToken = nil }
        let harness = ProfileHarness(signedIn: true, profiles: [translatesToPolish], cleanupKey: "", realCleaner: true)
        await harness.ready()
        await harness.coordinator.refreshCloudCleanupIfNeeded()
        #expect(harness.coordinator.cloud.account?.isActive == true)

        harness.frontmost.bundleIdentifier = code
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(localOnly) · \(noTranslation)")
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.inserter.inserted.last == raw)
    }

    @Test("Chip: with the key and the entitlement it claims Polishing and → PL")
    func chipKeyed() async throws {
        defer { ProviderFactory.cloudSessionToken = nil }
        let harness = ProfileHarness(signedIn: true, profiles: [translatesToPolish], cleanupKey: "k")
        await harness.ready()
        await harness.coordinator.refreshCloudCleanupIfNeeded()

        harness.frontmost.bundleIdentifier = code
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(geminiPolishing) · → PL")
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle?.translateTo == "pl")
    }

    @Test("Chip: turning global Polishing off mid-recording drops Polishing and translation, like the pipeline")
    func chipMidRecordingGlobalOff() async throws {
        defer { ProviderFactory.cloudSessionToken = nil }
        let harness = ProfileHarness(signedIn: true, profiles: [translatesToPolish], cleanupKey: "k", realCleaner: true)
        await harness.ready()
        await harness.coordinator.refreshCloudCleanupIfNeeded()

        harness.frontmost.bundleIdentifier = code
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(geminiPolishing) · → PL")
        harness.settings.cleanupEnabled = false
        #expect(harness.coordinator.profileChip == "Code · \(localOnly) · \(noTranslation)")
        // The real factory now builds NoCleanup (no network): the raw text lands.
        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.inserter.inserted.last == raw)
    }
}
