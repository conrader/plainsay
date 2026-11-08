import Foundation
import Testing
@testable import PlainsayCore

// Pure tests for app profiles (spec-appprofiles-xreview/SPEC.fixed.md §4,
// tests 1–5 and the policy half of 9b). Pipeline tests live in
// ProfilePipelineTests.swift.

@Suite("App profile resolver")
struct DictationProfileResolverTests {
    private let code = DictationProfile(name: "Code", bundleIdentifiers: ["com.microsoft.VSCode"])

    @Test("1. Exact and case-insensitive match; nil, Plainsay and no profiles resolve to Default")
    func resolve() {
        #expect(DictationProfileResolver.resolve(bundleIdentifier: "com.microsoft.VSCode", in: [code])?.id == code.id)
        #expect(DictationProfileResolver.resolve(bundleIdentifier: "com.Microsoft.vscode", in: [code])?.id == code.id)
        #expect(DictationProfileResolver.resolve(bundleIdentifier: nil, in: [code]) == nil)
        #expect(DictationProfileResolver.resolve(bundleIdentifier: "", in: [code]) == nil)
        #expect(DictationProfileResolver.resolve(bundleIdentifier: "com.apple.Notes", in: [code]) == nil)
        #expect(DictationProfileResolver.resolve(bundleIdentifier: "com.microsoft.VSCode", in: []) == nil)
        let own = DictationProfile(name: "Self", bundleIdentifiers: ["com.plainsay.dictation"])
        #expect(DictationProfileResolver.resolve(bundleIdentifier: "com.plainsay.dictation", in: [own]) == nil)
    }

    @Test("1. Two profiles claiming one app: the first wins")
    func firstWins() {
        let second = DictationProfile(name: "Other", bundleIdentifiers: ["com.microsoft.vscode"])
        #expect(DictationProfileResolver.resolve(bundleIdentifier: "com.microsoft.VSCode", in: [code, second])?.id == code.id)
    }
}

@Suite("App profile persistence")
@MainActor
struct DictationProfilePersistenceTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "plainsay.profiles.tests.\(UUID().uuidString)")!
    }

    @Test("2. Codable round trip through settings")
    func roundTrip() {
        let defaults = suite()
        let profile = DictationProfile(
            name: "Mail", bundleIdentifiers: ["com.apple.mail"], extraTerms: ["Konrad"],
            emailLayout: .composers, translation: .target("pl"), output: .copyOnly
        )
        PlainsaySettings(defaults: defaults).appProfiles = [profile]
        #expect(PlainsaySettings(defaults: defaults).appProfiles == [profile])
    }

    @Test("2. A missing key decodes to no profiles")
    func missingKey() {
        #expect(PlainsaySettings(defaults: suite()).appProfiles.isEmpty)
    }

    @Test("2. Corrupt data → no profiles, other settings intact")
    func corrupt() {
        let defaults = suite()
        let settings = PlainsaySettings(defaults: defaults)
        settings.emailModeEnabled = true
        settings.dictionary = TermDictionary(terms: ["kubectl"])
        defaults.set(Data("not json".utf8), forKey: "appProfiles")
        let reloaded = PlainsaySettings(defaults: defaults)
        #expect(reloaded.appProfiles.isEmpty)
        #expect(reloaded.emailModeEnabled)
        #expect(reloaded.dictionary.terms == ["kubectl"])
    }

    @Test("2. An unknown enum value drops only that profile")
    func lossy() throws {
        let good = DictationProfile(name: "Good", bundleIdentifiers: ["a.b"])
        var json = try #require(String(data: JSONEncoder().encode([good, good]), encoding: .utf8))
        // Make the second entry carry a value this build does not know.
        let range = try #require(json.range(of: "\"polishing\":\"inherit\"", options: .backwards))
        json.replaceSubrange(range, with: "\"polishing\":\"on\"")
        let decoded = DictationProfile.decodeList(Data(json.utf8))
        #expect(decoded == [good])
    }

    @Test("2. Fields missing from a stored profile mean Same as Default")
    func missingFields() {
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","name":"Old"}]"#
        #expect(DictationProfile.decodeList(Data(json.utf8)) == [DictationProfile(id: id, name: "Old")])
    }

    @Test("2. Translation override encodes to a stable string form")
    func translationCoding() throws {
        for value in [DictationProfile.TranslationOverride.inherit, .off, .target("pl")] {
            let data = try JSONEncoder().encode([value])
            #expect(try JSONDecoder().decode([DictationProfile.TranslationOverride].self, from: data) == [value])
        }
        #expect(String(data: try JSONEncoder().encode([DictationProfile.TranslationOverride.target("de")]), encoding: .utf8) == #"["to:de"]"#)
    }
}

@Suite("App profile session policy")
struct DictationProfilePolicyTests {
    private let defaults = DictationDefaults(
        dictionary: TermDictionary(terms: ["Plainsay", "Konrad"]),
        cleanupEnabled: true,
        emailModeEnabled: true,
        translationTargetLanguage: "de"
    )

    @Test("4. Every field inherit → the policy equals today's settings field for field")
    func inheritIsDefault() {
        let inherit = DictationSessionPolicy.make(defaults: defaults, profile: DictationProfile(name: "Inherit"))
        let none = DictationSessionPolicy.make(defaults: defaults)
        #expect(inherit.allowsCleanup == none.allowsCleanup)
        #expect(inherit.emailLayoutEnabled == none.emailLayoutEnabled)
        #expect(inherit.translateTo == none.translateTo)
        #expect(inherit.output == none.output)
        #expect(inherit.dictionary.normalizedTerms == none.dictionary.normalizedTerms)
        #expect(none.allowsCleanup && none.emailLayoutEnabled && none.translateTo == "de" && none.output == .paste)
        #expect(none.profileName == nil && inherit.profileName == "Inherit")
        // No defaults, no profile: exactly the pre-profiles standard policy.
        #expect(DictationSessionPolicy.make() == .standard)
    }

    @Test("3. Profile terms come first and duplicates are removed")
    func mergeOrder() {
        let profile = DictationProfile(name: "Code", extraTerms: ["kubectl", "konrad"])
        let policy = DictationSessionPolicy.make(defaults: defaults, profile: profile)
        #expect(policy.dictionary.normalizedTerms == ["kubectl", "konrad", "Plainsay"])
    }

    @Test("3. With 800 chars of global terms, all profile terms stay in the speech hint and global corrections still apply")
    func promptBudget() throws {
        // Letters only, so the dropped term has exactly one exact match.
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let filler = (0..<99).map { "Filler" + String(letters[$0 / 26]) + String(letters[$0 % 26]) }
        let global = filler + ["Zanzibarite"]
        let dropped = "Zanzibarite"
        let defaults = DictationDefaults(dictionary: TermDictionary(terms: global))
        let profile = DictationProfile(name: "Code", extraTerms: ["kubectl", "Kubernetes", "Plainsay"])
        let policy = DictationSessionPolicy.make(defaults: defaults, profile: profile)
        let prompt = try #require(policy.dictionary.asrPrompt())
        #expect(prompt.contains("kubectl") && prompt.contains("Kubernetes") && prompt.contains("Plainsay"))
        #expect(!prompt.contains(dropped))
        #expect(policy.dictionary.applyCorrections(to: dropped.lowercased()) == dropped)
        #expect(profile.overflowCount(defaultDictionary: defaults.dictionary) > 0)
        #expect(DictationProfile(name: "x").overflowCount(defaultDictionary: TermDictionary(terms: ["a"])) == 0)
    }

    @Test("9b. Polishing Off turns email and translation off with it; a stored combination is normalized away")
    func polishingOff() {
        let stored = DictationProfile(name: "Hand-edited", polishing: .off, emailLayout: .composers, translation: .target("pl"))
        let policy = DictationSessionPolicy.make(defaults: defaults, profile: stored)
        #expect(!policy.allowsCleanup && !policy.emailLayoutEnabled && policy.translateTo == nil)
        #expect(!stored.requestsCloudEntitlement)
        let saved = stored.normalized()
        #expect(saved.polishing == .off && saved.emailLayout == .inherit && saved.translation == .inherit)
    }

    @Test("Profile overrides: composers/off, translation target/off, Copy only")
    func overrides() {
        let off = DictationSessionPolicy.make(defaults: defaults, profile: DictationProfile(name: "A", emailLayout: .off, translation: .off))
        #expect(!off.emailLayoutEnabled && off.translateTo == nil && off.translationSuppressedByProfile)
        let quiet = DictationDefaults(cleanupEnabled: true)
        let on = DictationSessionPolicy.make(
            defaults: quiet, profile: DictationProfile(name: "B", emailLayout: .composers, translation: .target("pl"), output: .copyOnly)
        )
        #expect(on.emailLayoutEnabled && on.translateTo == "pl" && on.output == .copyOnly && !on.translationSuppressedByProfile)
        // Default Polishing off at recording start: nothing the cleaner does can run.
        let noPolish = DictationSessionPolicy.make(
            defaults: DictationDefaults(cleanupEnabled: false), profile: DictationProfile(name: "C", translation: .target("pl"))
        )
        #expect(!noPolish.allowsCleanup && noPolish.translateTo == nil)
    }

    @Test("Privacy wins over the profile; the profile's vocabulary still applies")
    func privacyWins() {
        let profile = DictationProfile(name: "Mail", extraTerms: ["kubectl"], emailLayout: .composers, translation: .target("pl"), output: .copyOnly)
        let policy = DictationSessionPolicy.make(privacy: .privateLocal, defaults: defaults, profile: profile)
        #expect(!policy.allowsCleanup && !policy.emailLayoutEnabled && policy.translateTo == nil)
        #expect(policy.output == .paste && !policy.writesHistory)
        #expect(policy.dictionary.normalizedTerms.first == "kubectl")
    }

    @Test("10. Only email composers or a translation target request the Cloud entitlement")
    func requestsCloud() {
        #expect(!DictationProfile(name: "a").requestsCloudEntitlement)
        #expect(!DictationProfile(name: "a", emailLayout: .off, translation: .off, output: .copyOnly).requestsCloudEntitlement)
        #expect(DictationProfile(name: "a", emailLayout: .composers).requestsCloudEntitlement)
        #expect(DictationProfile(name: "a", translation: .target("pl")).requestsCloudEntitlement)
    }
}

@Suite("App profile editor model")
struct DictationProfileEditorTests {
    @Test("5. A 21st profile, a 201st term, a 21st app and a 41-char name are rejected")
    func limits() throws {
        var profiles: [DictationProfile] = []
        for index in 0..<20 { _ = try profiles.addProfile(named: "P\(index)") }
        #expect(throws: DictationProfileEditError.tooManyProfiles) { try profiles.addProfile(named: "P20") }

        let id = profiles[0].id
        for index in 0..<200 { try profiles.addTerm("term\(index)", to: id) }
        #expect(throws: DictationProfileEditError.tooManyTerms) { try profiles.addTerm("term200", to: id) }

        for index in 0..<20 { try profiles.assign("com.example.app\(index)", to: id) }
        #expect(throws: DictationProfileEditError.tooManyApps) { try profiles.assign("com.example.app20", to: id) }

        #expect(throws: DictationProfileEditError.invalidName) { try DictationProfile.validated(name: String(repeating: "x", count: 41)) }
        #expect(throws: DictationProfileEditError.invalidName) { try DictationProfile.validated(name: "   ") }
        #expect(try DictationProfile.validated(name: String(repeating: "x", count: 40)).name.count == 40)
        #expect(DictationProfile(name: String(repeating: "y", count: 60)).normalized().name.count == 40)
    }

    @Test("An app belongs to one profile: assigning moves it")
    func move() throws {
        var profiles: [DictationProfile] = []
        let a = try profiles.addProfile(named: "A")
        let b = try profiles.addProfile(named: "B")
        try profiles.assign("com.apple.mail", to: a.id)
        #expect(profiles.owner(of: "COM.apple.mail", excluding: b.id)?.id == a.id)
        try profiles.assign("com.apple.Mail", to: b.id)
        #expect(profiles[0].bundleIdentifiers.isEmpty)
        #expect(profiles[1].bundleIdentifiers == ["com.apple.Mail"])
    }
}
