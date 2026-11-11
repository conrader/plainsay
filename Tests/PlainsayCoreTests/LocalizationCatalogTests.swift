import Foundation
import Testing

// Static checks on the app catalog: keys the code looks up exist in every
// shipped locale, every form keeps the English placeholders, and Slavic
// plural entries carry all four integer categories.

@Suite("App string catalog")
struct LocalizationCatalogTests {
    private static let locales = ["de", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "ru", "uk", "zh-Hans"]

    private func strings() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PlainsayApp/Resources/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    /// Every value of `key` in `language`: one string unit, or one per plural form.
    private func forms(_ strings: [String: Any], _ key: String, _ language: String) -> [String: String] {
        let localization = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any]
        func value(_ any: Any?) -> String? { ((any as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        if let single = value(localization) { return ["": single] }
        let plural = (localization?["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.compactMapValues(value)
    }

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dlfs]")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }
    }

    @Test("Formerly missing keys ship all 13 locales with English placeholders")
    func formerlyMissingKeys() throws {
        let strings = try strings()
        let keys = [
            "history.disabledDescription", "history.explainerOff", "history.explainerOn", "history.retention.days",
            "history.retention.year", "modelStatus.percentageOfSize", "permission.action.grant",
            "permission.action.openSettings", "settings.about.copied", "settings.about.copy", "settings.about.version",
            "settings.emailMode.explanation", "settings.emailMode.needsSubscription",
            "settings.modelDownloadNoteWithPreparation", "spokenLanguages.makePrimary",
            "settings.vocabulary.dictationCount",
        ]
        for key in keys {
            let english = try #require(forms(strings, key, "en").values.first, "\(key) en")
            for language in Self.locales {
                let values = forms(strings, key, language)
                #expect(!values.isEmpty, "\(key) \(language)")
                for (form, value) in values {
                    #expect(!value.isEmpty, "\(key) \(language) \(form)")
                    #expect(placeholders(value) == placeholders(english), "\(key) \(language) \(form): \(value)")
                }
            }
        }
        #expect(strings["settings.vocabulary.oneDictation"] == nil, "replaced by the plural dictationCount")
        #expect(strings["settings.vocabulary.manyDictations"] == nil, "replaced by the plural dictationCount")
    }

    @Test("English values match the code's fallbacks")
    func englishMatchesFallbacks() throws {
        let strings = try strings()
        #expect(forms(strings, "settings.about.version", "en") == ["": "Version %@"])
        #expect(forms(strings, "modelStatus.percentageOfSize", "en") == ["": "%d%% of %@"])
        #expect(forms(strings, "permission.action.openSettings", "en") == ["": "Open Settings…"])
        #expect(forms(strings, "spokenLanguages.makePrimary", "en") == ["": "Make %@ the main language"])
        #expect(forms(strings, "history.retention.days", "en")["other"] == "%d days")
        #expect(forms(strings, "settings.vocabulary.dictationCount", "en") == ["one": "in %d dictation", "other": "in %d dictations"])
        #expect(forms(strings, "settings.emailMode.explanation", "en")[""]?.contains("  ") == false)
    }

    @Test("pl/ru/uk plural entries carry one, few, many and other")
    func slavicPluralCoverage() throws {
        let strings = try strings()
        for key in strings.keys {
            for language in ["pl", "ru", "uk"] {
                let values = forms(strings, key, language)
                guard values[""] == nil, !values.isEmpty else { continue }
                #expect(Set(values.keys).isSuperset(of: ["one", "few", "many", "other"]), "\(key) \(language)")
            }
        }
    }
}
