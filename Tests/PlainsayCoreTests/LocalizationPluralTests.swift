import Foundation
import Testing
@testable import PlainsayCore

// `swift test` has no compiled `.lproj` tables in `Bundle.main`, so this
// builds a fixture bundle the way `Scripts/bundle.sh` does: it turns the
// catalog's plural variations into a `.stringsdict` (the format
// `xcstringstool compile` emits) and runs the real `Localization.plural`
// lookup against it. The strings come from the catalog, so a wrong Polish
// form there fails here.

@Suite("Plural strings")
struct LocalizationPluralTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let key = "profiles.vocabulary.overflow"
    private static let dictationCount = "settings.vocabulary.dictationCount"
    private static let retentionDays = "history.retention.days"

    /// `language → (plural category → template)` for `key`.
    private func variations(_ key: String = key) throws -> [String: [String: String]] {
        let url = Self.repoRoot.appendingPathComponent("Sources/PlainsayApp/Resources/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        var result: [String: [String: String]] = [:]
        for (language, value) in localizations {
            let plural = try #require(
                ((value as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any],
                "\(language) has no plural variations"
            )
            result[language] = plural.compactMapValues {
                (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
        }
        return result
    }

    /// Ships `key`'s catalog variations for `only` (every catalog language
    /// when nil), so a test can leave a language out and exercise fallback.
    private func fixtureBundle(_ key: String = key, only: Set<String>? = nil) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsay-plural-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (language, forms) in try variations(key) where only?.contains(language) ?? true {
            let lproj = dir.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            var rule: [String: Any] = [
                "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                "NSStringFormatValueTypeKey": "d",
            ]
            for (category, template) in forms { rule[category] = template }
            let dict: [String: Any] = [key: ["NSStringLocalizedFormatKey": "%#@count@", "count": rule]]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: lproj.appendingPathComponent("Localizable.stringsdict"))
            try Data("\"unused\" = \"unused\";\n".utf8).write(to: lproj.appendingPathComponent("Localizable.strings"))
        }
        return try #require(Bundle(path: dir.path))
    }

    private func render(_ count: Int, _ language: String, _ bundle: Bundle, key: String = key) -> String {
        Localization.plural(key, table: "Localizable", fallback: "FALLBACK", count: count, language: language, root: bundle)
    }

    @Test("Polish picks one / few / many for 0, 1, 2, 5, 22")
    func polish() throws {
        let bundle = try fixtureBundle()
        let expected = [
            0: "0 terminów może",
            1: "1 termin może",
            2: "2 terminy mogą",
            5: "5 terminów może",
            22: "22 terminy mogą",
        ]
        for (count, prefix) in expected {
            let text = render(count, "pl", bundle)
            #expect(text.hasPrefix(prefix), "\(count): \(text)")
        }
        #expect(render(1, "pl", bundle).contains("obejmują go"))
        #expect(render(5, "pl", bundle).contains("obejmują je"))
    }

    @Test("English picks term / terms")
    func english() throws {
        let bundle = try fixtureBundle()
        #expect(render(1, "en", bundle) == "1 term may not fit in the speech hint; it still gets local corrections.")
        for count in [0, 2, 5, 22] {
            #expect(render(count, "en", bundle) == "\(count) terms may not fit in the speech hint; they still get local corrections.")
        }
    }

    @Test("Polish also covers 12, 25 and 112")
    func polishTeens() throws {
        let bundle = try fixtureBundle()
        for (count, prefix) in [12: "12 terminów może", 25: "25 terminów może", 112: "112 terminów może"] {
            #expect(render(count, "pl", bundle).hasPrefix(prefix), "\(count)")
        }
    }

    @Test("An English template falling in for ru/uk keeps English plural rules")
    func englishFallbackUsesEnglishRules() throws {
        // Overflow ships only en/pl; under Russian rules 21, 31 and 101 are `one`.
        let bundle = try fixtureBundle(only: ["en"])
        for language in ["ru", "uk", "pl"] {
            #expect(render(1, language, bundle) == "1 term may not fit in the speech hint; it still gets local corrections.")
            for count in [2, 11, 21, 31, 101] {
                #expect(
                    render(count, language, bundle)
                        == "\(count) terms may not fit in the speech hint; they still get local corrections.",
                    "\(language) \(count)"
                )
            }
        }
    }

    @Test("No table at all returns the caller's filled-in fallback untouched")
    func missingEverywhere() throws {
        let bundle = try fixtureBundle(only: [])
        #expect(render(21, "ru", bundle) == "FALLBACK")
    }

    @Test("Occurrence label follows ru/uk/pl plural rules (21 and 101 are singular)")
    func occurrences() throws {
        let bundle = try fixtureBundle(Self.dictationCount)
        let expected: [String: [Int: String]] = [
            "ru": [1: "в 1 записи", 2: "в 2 записях", 5: "в 5 записях", 11: "в 11 записях",
                   21: "в 21 записи", 22: "в 22 записях", 31: "в 31 записи", 101: "в 101 записи", 111: "в 111 записях"],
            "uk": [1: "у 1 записі", 2: "у 2 записах", 5: "у 5 записах", 11: "у 11 записах",
                   21: "у 21 записі", 22: "у 22 записах", 31: "у 31 записі", 101: "у 101 записі", 111: "у 111 записах"],
            "pl": [1: "w 1 dyktowaniu", 2: "w 2 dyktowaniach", 21: "w 21 dyktowaniach", 22: "w 22 dyktowaniach"],
            "en": [1: "in 1 dictation", 2: "in 2 dictations", 21: "in 21 dictations"],
        ]
        for (language, cases) in expected {
            for (count, text) in cases {
                #expect(render(count, language, bundle, key: Self.dictationCount) == text, "\(language) \(count)")
            }
        }
    }

    @Test("Retention days follow ru/uk/pl plural rules")
    func retentionDays() throws {
        let bundle = try fixtureBundle(Self.retentionDays)
        let expected: [String: [Int: String]] = [
            "ru": [1: "1 день", 2: "2 дня", 7: "7 дней", 21: "21 день", 30: "30 дней", 90: "90 дней"],
            "uk": [1: "1 день", 2: "2 дні", 7: "7 днів", 21: "21 день", 30: "30 днів", 90: "90 днів"],
            "pl": [1: "1 dzień", 2: "2 dni", 7: "7 dni", 30: "30 dni"],
            "en": [1: "1 day", 7: "7 days", 90: "90 days"],
        ]
        for (language, cases) in expected {
            for (count, text) in cases {
                #expect(render(count, language, bundle, key: Self.retentionDays) == text, "\(language) \(count)")
            }
        }
    }

    @Test("Polish catalog has every integer plural category")
    func categories() throws {
        let pl = try #require(try variations()["pl"])
        #expect(Set(pl.keys).isSuperset(of: ["one", "few", "many", "other"]))
        for template in pl.values { #expect(template.contains("%d")) }
    }

    @Test("Split Off labels and formerly missing menu/vocabulary keys ship en and pl")
    func addedKeys() throws {
        let url = Self.repoRoot.appendingPathComponent("Sources/PlainsayApp/Resources/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        func value(_ key: String, _ language: String) -> String? {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            return ((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(strings["profiles.off"] == nil, "replaced by the per-picker keys")
        #expect(value("profiles.email.off", "pl") == "Wyłączony")
        #expect(value("profiles.translation.off", "pl") == "Wyłączone")
        let keys = [
            "menu.status.hold", "menu.status.holdOrTap", "menu.status.tap",
            "menu.translate.active", "menu.translate.idle", "menu.translate.locked", "menu.translate.off",
            "menu.translate.shortcut", "settings.vocabulary.accept", "settings.vocabulary.dismiss",
            "settings.vocabulary.suggested",
        ]
        for key in keys {
            #expect(value(key, "en")?.isEmpty == false, "\(key) en")
            #expect(value(key, "pl")?.isEmpty == false, "\(key) pl")
        }
    }
}
