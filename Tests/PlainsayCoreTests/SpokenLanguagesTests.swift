import Foundation
import Testing
@testable import PlainsayCore

@Suite("Spoken languages")
@MainActor
struct SpokenLanguagesTests {
    @Test("Defaults to empty — full auto-detect")
    func defaultsToEmpty() {
        let settings = PlainsaySettings(
            defaults: UserDefaults(suiteName: "plainsay.languages.\(UUID().uuidString)")!
        )
        #expect(settings.spokenLanguages.isEmpty)
        #expect(settings.primaryLanguage == nil)
    }

    @Test("Persists in order across relaunch")
    func persistsInOrder() {
        let suiteName = "plainsay.languages.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = PlainsaySettings(defaults: defaults)

        settings.spokenLanguages = ["pl", "en"]

        let reloaded = PlainsaySettings(defaults: defaults)
        #expect(reloaded.spokenLanguages == ["pl", "en"])
        #expect(reloaded.primaryLanguage == "pl")
    }

    @Test("primaryCode strips region and script suffixes")
    func primaryCodeStripsSuffixes() {
        #expect(SupportedLanguage.primaryCode("en-US") == "en")
        #expect(SupportedLanguage.primaryCode("pt_BR") == "pt")
        #expect(SupportedLanguage.primaryCode("PL") == "pl")
    }

    @Test("named resolves a known code and falls back for an unknown one")
    func namedResolvesKnownCode() {
        #expect(SupportedLanguage.named("pl") == "Polish")
        #expect(SupportedLanguage.named("en-US") == "English")
        #expect(SupportedLanguage.named("xx") == "xx")
    }

    @Test("The list has no duplicate codes")
    func noDuplicateCodes() {
        let codes = SupportedLanguage.all.map(\.code)
        #expect(codes.count == Set(codes).count)
    }
}
