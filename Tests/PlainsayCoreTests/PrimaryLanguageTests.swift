import Foundation
import Testing
@testable import PlainsayCore

/// The first spoken language is load-bearing: it is what single-language
/// engines are set to, and what a wrong-language transcript falls back to.
@Suite("Main language")
@MainActor
struct PrimaryLanguageTests {
    private func makeSettings() -> PlainsaySettings {
        PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!)
    }

    @Test("The first listed language is the primary one")
    func firstIsPrimary() {
        let settings = makeSettings()
        settings.spokenLanguages = ["en", "pl"]
        #expect(settings.primaryLanguage == "en")

        settings.spokenLanguages = ["pl", "en"]
        #expect(settings.primaryLanguage == "pl")
    }

    @Test("With no languages chosen there is no primary, and that means auto-detect")
    func emptyMeansAuto() {
        #expect(makeSettings().primaryLanguage == nil)
    }

    @Test("Promoting a language moves it to the front without losing the others")
    func promotionKeepsTheRest() {
        // Mirrors what the "Make main" button does. Before it existed the only
        // route was removing every language above the target and adding them
        // back, which is a puzzle rather than a control — and the reason the
        // ordering advice was unactionable.
        var languages = ["en", "pl", "de"]
        let promoted = "pl"
        languages.removeAll { $0 == promoted }
        languages.insert(promoted, at: 0)

        #expect(languages == ["pl", "en", "de"])
    }

    @Test("Promoting the language that is already first changes nothing")
    func promotingFirstIsANoOp() {
        var languages = ["pl", "en"]
        let promoted = "pl"
        languages.removeAll { $0 == promoted }
        languages.insert(promoted, at: 0)

        #expect(languages == ["pl", "en"])
    }
}
