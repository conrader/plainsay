import Foundation
import Testing

// remember-correction v1 strings (SPEC.fixed.md §2.7): every key the App
// reads through `RuleText` has English and Polish, with the same placeholders.

@Suite("Replacement rule strings")
struct ReplacementRuleStringsTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let keys = [
        "rules.offer.title", "rules.offer.body", "rules.offer.remember", "rules.offer.notNow",
        "rules.confirm.from", "rules.confirm.to", "rules.confirm.scope", "rules.confirm.inflection",
        "rules.confirm.vocabulary", "rules.confirm.vocabularyFuzzy", "rules.confirm.save",
        "rules.confirm.saveAnyway", "rules.confirm.cancel", "rules.saved", "rules.forget", "rules.forgotten",
        "rules.inverse", "rules.inverse.off", "rules.inverse.keep", "rules.inverse.done",
        "rules.duplicate", "rules.duplicate.replace", "rules.warn.short", "rules.warn.common",
        "rules.warn.factual", "rules.reject.empty", "rules.reject.same", "rules.reject.contains",
        "rules.reject.tooLong", "rules.reject.tooShort", "rules.reject.vocabulary", "rules.reject.limit",
        "settings.rules.title", "settings.rules.toggle", "settings.rules.explanation",
        "settings.rules.translation", "settings.rules.empty", "settings.rules.source.correction",
        "settings.rules.source.manual", "settings.rules.delete", "settings.rules.enable",
    ]

    private func value(_ strings: [String: Any], _ key: String, _ language: String) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[@dfs]"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }.sorted()
    }

    @Test("Every rule key has English and Polish with matching placeholders")
    func catalog() throws {
        let url = Self.repoRoot.appendingPathComponent("Sources/PlainsayApp/Resources/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        #expect(Set(Self.keys).count == Self.keys.count)
        for key in Self.keys {
            let en = try #require(value(strings, key, "en"), "\(key) en")
            let pl = try #require(value(strings, key, "pl"), "\(key) pl")
            #expect(!en.isEmpty && !pl.isEmpty, "\(key)")
            #expect(placeholders(en) == placeholders(pl), "\(key) placeholders")
            // Native Polish quotation marks, never ASCII ones.
            #expect(!pl.contains("\""), "\(key) pl quotes")
        }
    }
}
