import Foundation
import Testing
@testable import PlainsayCore

// Loading stored rules that did not come from `save`: bounded work, stable
// identity. Pure Core.

private func decode(_ json: String) throws -> ReplacementRuleSet {
    try JSONDecoder().decode(ReplacementRuleSet.self, from: Data(json.utf8))
}

private func rule(_ from: String, _ to: String, id: String? = nil) -> String {
    func quoted(_ s: String) -> String { String(data: try! JSONEncoder().encode(s), encoding: .utf8)! }
    let idField = id.map { #""id":"\#($0)","# } ?? ""
    return #"{\#(idField)"from":\#(quoted(from)),"to":\#(quoted(to))}"#
}

private func set(_ rules: [String]) -> String { #"{"rules":[\#(rules.joined(separator: ","))]}"# }

@Suite("Replacement rules: loading")
struct ReplacementRuleLoadingTests {
    @Test("Raw phrases are bounded before normalization, padding included")
    func rawSize() throws {
        let maxFrom = ReplacementRuleValidator.maxFromLength, maxTo = ReplacementRuleValidator.maxToLength
        let pad = { (n: Int) in String(repeating: " ", count: n) }
        let loaded = try decode(set([
            rule("jason" + pad(maxFrom - 5), "JSON"),               // exactly at the limit: kept
            rule(pad(30) + "pyton" + pad(maxFrom - 34), "Python"),  // 61 raw, 5 normalized: dropped
            rule("acme", "ACME" + pad(maxTo - 3)),                  // 81 raw: dropped
            rule(String(repeating: "k", count: 100_000), "K"),      // huge: dropped, the rest survive
            rule("kowalsky", String(repeating: "\u{1F600}", count: maxTo + 1)),
            rule("gogle", "Google"),
        ])).rules
        #expect(loaded.map(\.from) == ["jason" + pad(maxFrom - 5), "gogle"])
        #expect(!ReplacementRuleValidator.withinBounds(from: " " + String(repeating: "a", count: maxFrom), to: "A"))
        #expect(ReplacementRuleValidator.rawWithinSize(String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 10),
                                                       max: 10))
    }

    @Test("Decoding stops after rawElementLimit stored elements")
    func elementCount() throws {
        let junk = Array(repeating: "{}", count: ReplacementRuleSet.rawElementLimit - 1)
        #expect(try decode(set(junk + [rule("jason", "JSON")])).rules.map(\.from) == ["jason"])
        #expect(try decode(set(junk + ["{}", rule("jason", "JSON")])).rules.isEmpty)
        let retired = Array(repeating: #"{"to":"x"}"#, count: ReplacementRuleSet.rawElementLimit)
        let json = #"{"rules":[],"retiredTargets":[\#(retired.joined(separator: ",")),{"to":"Late","retiredAt":1}]}"#
        #expect(try decode(json).retiredTargets.isEmpty)
    }

    @Test("Phrases equal after NFC, case and whitespace folding are one rule; the first wins")
    func normalizedDedupe() throws {
        let loaded = try decode(set([
            rule("Cafe\u{301}   Noir", "Café Noir"),
            rule("café noir", "CAFE NOIR"),
            rule("CAFÉ\u{00A0}NOIR", "Cafe Noir"),
            rule(" café noir ", "Noir"),
            rule("cafe noir", "Cafe-Noir"),   // no accent: a different phrase
        ])).rules
        #expect(loaded.map(\.to) == ["Café Noir", "Cafe-Noir"])
    }

    @Test("Repaired and missing ids are the same on every reload and after a save")
    func stableRepairedIDs() throws {
        let shared = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let json = set([
            rule("jason", "JSON", id: shared),
            rule("kowalsky", "Kowalski", id: shared),
            rule("pyton", "Python", id: shared),
            rule("gogle", "Google"),
            rule("acme", "ACME", id: "not-a-uuid"),
        ])
        let first = try decode(json), second = try decode(json)
        #expect(first.rules.map(\.id) == second.rules.map(\.id))
        #expect(Set(first.rules.map(\.id)).count == 5)
        #expect(first.rules[0].id.uuidString == shared)
        // Saved and loaded again (as Settings does), the ids do not move.
        let resaved = try JSONDecoder().decode(ReplacementRuleSet.self, from: JSONEncoder().encode(first))
        #expect(resaved.rules.map(\.id) == first.rules.map(\.id))
        // The repaired ids depend on the stored rule, not on load order luck.
        let swapped = try decode(set([
            rule("jason", "JSON", id: shared),
            rule("pyton", "Python", id: shared),
            rule("kowalsky", "Kowalski", id: shared),
        ])).rules
        #expect(swapped[1].id == first.rules[2].id && swapped[2].id == first.rules[1].id)
    }

    @Test("A derived id that collides with a stored one is derived again")
    func derivedCollision() throws {
        let shared = UUID()
        let collision = ReplacementRuleSet.derivedID("duplicate\u{1F}\(shared.uuidString)\u{1F}kowalsky\u{1F}1")
        let loaded = ReplacementRuleSet.loadable([
            ReplacementRule(id: shared, from: "jason", to: "JSON"),
            ReplacementRule(id: collision, from: "pyton", to: "Python"),
            ReplacementRule(id: shared, from: "kowalsky", to: "Kowalski"),
        ])
        #expect(Set(loaded.map(\.id)).count == 3)
        #expect(loaded[2].id == ReplacementRuleSet.derivedID("duplicate\u{1F}\(shared.uuidString)\u{1F}kowalsky\u{1F}2"))
    }
}
