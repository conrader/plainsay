import Foundation
import Testing
@testable import PlainsayCore

private func assess(_ from: String, _ to: String, vocabulary: [String] = [],
                    rules: ReplacementRuleSet = ReplacementRuleSet()) -> ReplacementAssessment {
    ReplacementRuleValidator.assess(from: from, to: to, rules: rules, vocabulary: vocabulary)
}

@Suite("Replacement rules: validator")
struct ReplacementRuleValidatorTests {
    @Test("Spelling fixes of names and products are offered, never treated as facts")
    func namePairsOffer() {
        #expect(assess("jason", "JSON") == .offer)
        #expect(assess("Kowalsky", "Kowalski") == .offer)
        #expect(assess("dżejson", "JSON") == .offer)
        #expect(assess("Grzegosz", "Grzegorz") == .offer)
        #expect(assess("lumen tar", "Lumenta") == .offer)
        #expect(assess("plain say", "Plainsay") == .offer)
        // The default Vocabulary already holds "Plainsay"; a rule that agrees
        // with it is not a fight between the two stores.
        #expect(assess("plain say", "Plainsay", vocabulary: ["Plainsay"]) == .offer)
        #expect(assess("Anna", "Ania") == .offerWithWarning(.shortWord))
        #expect(assess("e-mail", "email").isOffered)
    }

    private static let factualPairs: [(String, String, ReplacementSuppression)] = [
        ("Tuesday", "Thursday", .date), ("wtorek", "czwartek", .date), ("wtorku", "czwartku", .date),
        ("we wtorek", "we czwartek", .date), ("May", "June", .date),
        ("tomorrow", "today", .date), ("jutro", "dziś", .date),
        ("$125", "$150", .structuredDetail), ("10:30", "11:00", .structuredDetail),
        ("anna@x.pl", "ana@x.pl", .structuredDetail), ("jan@firma.pl", "jan@firma.com", .structuredDetail),
        ("fifteen", "50", .structuredDetail),
        ("fifteen", "fifty", .spelledNumber), ("piętnaście", "pięćdziesiąt", .spelledNumber),
    ]

    @Test("Dates, amounts, times, e-mail addresses and spelled numbers are not offered")
    func factualSuppressed() {
        for (from, to, why) in Self.factualPairs {
            let result = assess(from, to)
            #expect(result == .suppressOffer(why), "\(from) → \(to)")
            #expect(!result.isOffered, "\(from) → \(to)")
        }
    }

    @Test("A case-only fix of a date word is not a factual change")
    func caseOnlyDate() {
        #expect(assess("monday", "Monday") == .offer)
    }

    @Test("Short and function words: rejected or not offered, per word")
    func shortAndCommon() {
        #expect(assess("to", "too") == .reject(.tooShort))
        #expect(assess("na", "nad") == .reject(.tooShort))
        #expect(assess("the", "a") == .suppressOffer(.commonWord))
        #expect(assess("of the", "off the") == .suppressOffer(.commonWord))
        #expect(assess("się", "sie") == .suppressOffer(.commonWord))
        #expect(assess("cat", "Kat") == .offerWithWarning(.shortWord))
        #expect(assess("jira", "Jira") == .offerWithWarning(.shortWord))
    }

    @Test("Containment, case-only, length, vocabulary, limit, empty and identical")
    func rejections() {
        #expect(assess("Claude", "Claude Code") == .reject(.containsFrom))
        #expect(assess("iphone", "iPhone") == .offer)
        #expect(assess("one two three four five", "x") == .reject(.fromTooLong))
        #expect(assess("jason", "a b c d e f g h i") == .reject(.toTooLong))
        #expect(assess("jason", "JSON", vocabulary: ["Jason"]) == .reject(.vocabularyTerm))
        #expect(assess("Plain-Say", "PlainSay", vocabulary: ["Plainsay"]) == .reject(.vocabularyTerm))
        #expect(assess("", "JSON") == .reject(.empty))
        #expect(assess("jason", "   ") == .reject(.empty))
        #expect(assess("ja\nson", "JSON") == .reject(.empty))
        #expect(assess("jason", "jason") == .reject(.identical))
        #expect(assess("plain  say", "plain say") == .reject(.identical))
        let full = ReplacementRuleSet(rules: (0..<ReplacementRuleSet.limit).map {
            ReplacementRule(from: "term\($0)x", to: "Term\($0)X")
        })
        #expect(assess("jason", "JSON", rules: full) == .reject(.limitReached))
        #expect(assess("term7x", "TERM7X", rules: full) == .offer)
    }
}

@Suite("Replacement rules: Remember this correction offer")
struct RememberCorrectionOfferTests {
    private func offer(_ command: DictationCorrectionCommand, matched: String? = nil, applied: Bool = true,
                       isUndo: Bool = false, rules: ReplacementRuleSet = ReplacementRuleSet(),
                       vocabulary: [String] = []) -> RememberCorrectionOffer? {
        var surface = matched
        if surface == nil, case .replace(let from, _) = command { surface = from }
        return RememberCorrectionOffer.make(command: command, matched: surface, applied: applied,
                                            isUndo: isUndo, rules: rules, vocabulary: vocabulary)
    }

    @Test("Offered after a verified replace, using the matched surface text")
    func offered() throws {
        #expect(offer(.replace("plain say", "Plainsay"), matched: "Plain Say")
            == .remember(from: "Plain Say", to: "Plainsay", warning: nil))
        let polish = try DictationCorrectionCommand.parse("Zamień dżejson na JSON.")
        #expect(polish == .replace("dżejson", "JSON"))
        #expect(offer(polish) == .remember(from: "dżejson", to: "JSON", warning: nil))
        #expect(offer(.replace("cat", "Kat")) == .remember(from: "cat", to: "Kat", warning: .shortWord))
    }

    @Test("No offer after undo, rewrite, Copy only or a failed apply, factual pairs, or switch off")
    func notOffered() throws {
        #expect(offer(.undo) == nil)
        #expect(offer(.rewrite("make it formal")) == nil)
        #expect(offer(.replace("jason", "JSON"), applied: false) == nil)
        #expect(offer(.replace("jason", "JSON"), isUndo: true) == nil)
        #expect(RememberCorrectionOffer.make(command: .replace("jason", "JSON"), matched: nil, applied: true,
                                             isUndo: false, rules: ReplacementRuleSet(), vocabulary: []) == nil)
        for spoken in ["Change Tuesday to Thursday.", "Zamień wtorek na czwartek.", "change $125 to $150",
                       "change 10:30 to 11:00", "change anna@x.pl to ana@x.pl", "zmień piętnaście na pięćdziesiąt"] {
            let command = try DictationCorrectionCommand.parse(spoken)
            #expect(offer(command) == nil, "\(spoken)")
        }
        #expect(offer(.replace("jason", "JSON"), vocabulary: ["Jason"]) == nil)
        #expect(offer(.replace("jason", "JSON"), rules: ReplacementRuleSet(isEnabled: false)) == nil)
    }

    @Test("Correcting a rule's output back offers to turn that rule off")
    func inverse() throws {
        let rule = ReplacementRule(from: "jason", to: "JSON")
        let rules = ReplacementRuleSet(rules: [rule])
        let command = try DictationCorrectionCommand.parse("change JSON to jason")
        #expect(offer(command, matched: "JSON", rules: rules) == .inverse(rule))
        var disabled = rules
        disabled.setEnabled(false, id: rule.id)
        #expect(offer(command, matched: "JSON", rules: disabled) != .inverse(rule))
    }
}

@Suite("Replacement rules: lossy decoding")
struct ReplacementRuleDecodingTests {
    private func decode(_ json: String) throws -> ReplacementRuleSet {
        try JSONDecoder().decode(ReplacementRuleSet.self, from: Data(json.utf8))
    }

    @Test("Round trip")
    func roundTrip() throws {
        let set = ReplacementRuleSet(isEnabled: false, rules: [
            ReplacementRule(from: "jason", to: "JSON", source: .manual,
                            createdAt: Date(timeIntervalSinceReferenceDate: 1_000)),
            ReplacementRule(from: "Kowalsky", to: "Kowalski", isEnabled: false,
                            createdAt: Date(timeIntervalSinceReferenceDate: 2_000)),
        ])
        let data = try JSONEncoder().encode(set)
        #expect(try JSONDecoder().decode(ReplacementRuleSet.self, from: data) == set)
    }

    @Test("One bad rule is dropped and the rest survive; unknown fields are ignored")
    func partialDecode() throws {
        let set = try decode("""
        {"isEnabled": true, "future": 1, "rules": [
          {"from": "jason", "to": "JSON", "isEnabled": true, "source": "correction", "extra": "x"},
          {"from": "nope"},
          {"from": 12, "to": "x"},
          {"from": "  ", "to": "x"},
          "not an object",
          {"from": "Kowalsky", "to": "Kowalski", "source": "learnedFromCloud", "id": "not-a-uuid"},
          {"from": "pyton", "to": "Python", "isEnabled": false}
        ]}
        """)
        #expect(set.isEnabled)
        #expect(set.rules.map(\.from) == ["jason", "Kowalsky", "pyton"])
        #expect(set.rules[1].source == .manual)
        #expect(set.rules[1].isEnabled)
        #expect(!set.rules[2].isEnabled)
        #expect(set.apply(to: "jason and Kowalsky and pyton").text == "JSON and Kowalski and pyton")
    }

    @Test("Missing or malformed fields fall back without throwing")
    func fallbacks() throws {
        #expect(try decode("{}") == ReplacementRuleSet())
        let wrongRules = try decode(#"{"isEnabled": false, "rules": "oops"}"#)
        #expect(!wrongRules.isEnabled)
        #expect(wrongRules.rules.isEmpty)
        #expect(try decode(#"{"isEnabled": "yes", "rules": []}"#).isEnabled)
    }
}
