import Foundation
import Testing
@testable import PlainsayCore

// App profiles review fixes, round 2 (appprofiles-fix2-job/REVIEW-sol.md 1–2):
// the HUD chip follows a Polishing key added or removed mid-recording, the way
// `ProviderFactory.makeCleaner` does, and reads the Keychain at most once per
// provider rather than on every 30 Hz redraw — including after a provider
// switch. Keys live in `KeyStoreBox`, never the login Keychain.

/// Stands in for the Keychain and counts reads.
@MainActor
final class KeyStoreBox {
    var keys: [CleanupProvider: String]
    private(set) var lookups = 0

    init(_ keys: [CleanupProvider: String]) { self.keys = keys }

    func install(in settings: PlainsaySettings) {
        settings.cleanupKeyLookup = { provider in
            self.lookups += 1
            return self.keys[provider] ?? ""
        }
        settings.cleanupKeyStore = { key, provider in self.keys[provider] = key }
        // Speech and legacy Gemini writes address a Keychain account; land
        // them on the Polishing provider sharing that account, as the
        // Keychain would.
        settings.accountKeyStore = { key, account in
            for provider in CleanupProvider.allCases where provider.keychainAccount == account {
                self.keys[provider] = key
            }
        }
    }
}

@Suite("Profile chip follows credential changes", .serialized)
@MainActor
struct ProfileCredentialChangeTests {
    private let code = "com.microsoft.VSCode"
    private let raw = "um so the thing is uh it works"

    private var translatesToPolish: DictationProfile {
        DictationProfile(name: "Code", bundleIdentifiers: [code], translation: .target("pl"))
    }

    private var localOnly: String { DictationProfileRoute.label(source: .onDevice, polishing: false, provider: .gemini) }
    private func polishing(_ provider: CleanupProvider) -> String {
        DictationProfileRoute.label(source: .onDevice, polishing: true, provider: provider)
    }
    private var noTranslation: String { Localization.coreString("hud.profile.noTranslation", fallback: "no translation") }

    private func makeHarness(keys: [CleanupProvider: String], realCleaner: Bool) async -> (ProfileHarness, KeyStoreBox) {
        let harness = ProfileHarness(signedIn: true, profiles: [translatesToPolish], realCleaner: realCleaner)
        let store = KeyStoreBox(keys)
        store.install(in: harness.settings)
        await harness.ready()
        await harness.coordinator.refreshCloudCleanupIfNeeded()
        #expect(harness.coordinator.cloud.account?.isActive == true)
        return (harness, store)
    }

    @Test("Settings: key presence is read once per provider and every key write clears it")
    func presenceCache() {
        let settings = PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!)
        let store = KeyStoreBox([.gemini: "k"])
        store.install(in: settings)
        for _ in 0..<30 { #expect(settings.hasAPIKey(for: .gemini)) }
        #expect(store.lookups == 1)
        settings.setAPIKey("", for: .gemini)
        #expect(!settings.hasAPIKey(for: .gemini))
        #expect(store.lookups == 2)
    }

    @Test("Settings: a speech-key write to a shared account clears cached Polishing presence")
    func asrWriteInvalidates() {
        let settings = PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!)
        let store = KeyStoreBox([:])
        store.install(in: settings)
        #expect(!settings.hasAPIKey(for: .openAI))
        settings.setAPIKey("sk", for: ASRProvider.openAI)
        #expect(settings.hasAPIKey(for: .openAI), "the OpenAI account serves speech and Polishing")
        #expect(store.lookups == 2)
        // An unrelated speech account still clears the cache (reads again, same answer).
        settings.setAPIKey("g", for: ASRProvider.groq)
        #expect(settings.hasAPIKey(for: .openAI))
        #expect(store.lookups == 3)
    }

    @Test("Settings: the legacy Gemini key setter clears cached Gemini presence")
    func legacyGeminiWriteInvalidates() {
        let settings = PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!)
        let store = KeyStoreBox([.gemini: "k"])
        store.install(in: settings)
        #expect(settings.hasAPIKey(for: .gemini))
        settings.geminiAPIKey = ""
        #expect(!settings.hasAPIKey(for: .gemini))
        settings.geminiAPIKey = "k2"
        #expect(settings.hasAPIKey(for: .gemini))
        #expect(store.lookups == 3)
    }

    @Test("Key removed outside Plainsay: the next recording drops Polishing, matching the factory")
    func keyRemovedExternally() async throws {
        defer { ProviderFactory.cloudSessionToken = nil }
        let (harness, store) = await makeHarness(keys: [.gemini: "k"], realCleaner: true)
        #expect(harness.settings.hasAPIKey(for: .gemini)) // cached, e.g. by the profile editor
        store.keys[.gemini] = nil // Keychain Access: no settings write, no invalidation
        #expect(harness.settings.hasAPIKey(for: .gemini), "between recordings the cached answer stands")

        harness.frontmost.bundleIdentifier = code
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(localOnly) · \(noTranslation)")
        #expect(ProviderFactory.makeCleaner(harness.settings) is NoCleanup)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.inserter.inserted.last == raw)
    }

    @Test("Key added outside Plainsay: the next recording claims Polishing and → PL, matching the factory")
    func keyAddedExternally() async throws {
        defer { ProviderFactory.cloudSessionToken = nil }
        let (harness, store) = await makeHarness(keys: [:], realCleaner: false)
        #expect(!harness.settings.hasAPIKey(for: .gemini))
        store.keys[.gemini] = "k"

        harness.frontmost.bundleIdentifier = code
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(polishing(.gemini)) · → PL")
        #expect(ProviderFactory.makeCleaner(harness.settings) is GeminiCleanupService)
        let before = store.lookups
        for _ in 0..<30 { _ = harness.coordinator.profileChip }
        #expect(store.lookups == before, "one read per recording boundary, none per redraw")

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle?.translateTo == "pl")
    }

    @Test("Removing the key before release: the chip drops Polishing and → PL, and the real factory pastes raw text")
    func keyRemovedMidRecording() async throws {
        defer { ProviderFactory.cloudSessionToken = nil }
        let (harness, _) = await makeHarness(keys: [.gemini: "k"], realCleaner: true)

        harness.frontmost.bundleIdentifier = code
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(polishing(.gemini)) · → PL")
        harness.settings.setAPIKey("", for: .gemini)
        #expect(harness.coordinator.profileChip == "Code · \(localOnly) · \(noTranslation)")
        #expect(ProviderFactory.makeCleaner(harness.settings) is NoCleanup)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.inserter.inserted.last == raw)
    }

    @Test("Adding the key before release: the chip claims Polishing and → PL, matching what the factory builds")
    func keyAddedMidRecording() async throws {
        defer { ProviderFactory.cloudSessionToken = nil }
        // The fake cleaner stands in for the network; the factory check below
        // shows the real one would be built.
        let (harness, _) = await makeHarness(keys: [:], realCleaner: false)

        harness.frontmost.bundleIdentifier = code
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(localOnly) · \(noTranslation)")
        harness.settings.setAPIKey("k", for: .gemini)
        #expect(harness.coordinator.profileChip == "Code · \(polishing(.gemini)) · → PL")
        #expect(ProviderFactory.makeCleaner(harness.settings) is GeminiCleanupService)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle?.translateTo == "pl")
    }

    @Test("Provider switch mid-recording: one Keychain read for the new provider, none per chip redraw")
    func providerSwitchLookupCount() async throws {
        defer { ProviderFactory.cloudSessionToken = nil }
        let (harness, store) = await makeHarness(keys: [.gemini: "g", .anthropic: "a"], realCleaner: false)

        harness.frontmost.bundleIdentifier = code
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.profileChip == "Code · \(polishing(.gemini)) · → PL")
        var before = store.lookups
        for _ in 0..<30 { _ = harness.coordinator.profileChip }
        #expect(store.lookups == before, "unchanged provider: no reads per redraw")

        harness.settings.cleanupProvider = .anthropic
        before = store.lookups
        #expect(harness.coordinator.profileChip == "Code · \(polishing(.anthropic)) · → PL")
        for _ in 0..<30 { _ = harness.coordinator.profileChip }
        #expect(store.lookups == before + 1, "switched provider: read once, then cached")
        #expect(ProviderFactory.makeCleaner(harness.settings) is AnthropicCleanupService)

        harness.coordinator.handleHotkeyEdge(.up(at: 1))
        try await harness.settle()
        #expect(harness.cleaner.receivedStyle?.translateTo == "pl")
    }
}
