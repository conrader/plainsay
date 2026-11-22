import Foundation
import Testing
@testable import PlainsayCore

/// The remember-correction spike's kill criteria, run on real text:
/// 20 realistic rules over the 50 LibriSpeech references and a hand-written
/// Polish corpus (Benchmark/data/replacement-rules-spike.json).
@Suite("Replacement rules: spike corpus and kill criteria")
struct ReplacementRulesCorpusTests {
    private struct Fixture: Decodable {
        struct Pair: Decodable { let from: String; let to: String }
        struct Sentence: Decodable { let text: String; let expected: String? }
        let rules: [Pair]
        let polish: [Sentence]
    }
    private struct Utterance: Decodable { let reference: String }

    private static let data = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Benchmark/data")

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: Self.data.appending(path: "replacement-rules-spike.json")))
    }

    private func ruleSet(_ fixture: Fixture) -> ReplacementRuleSet {
        ReplacementRuleSet(rules: fixture.rules.map { ReplacementRule(from: $0.from, to: $0.to) })
    }

    @Test("Kill criterion 1: no unintended replacement in 50 LibriSpeech references")
    func librispeech() throws {
        let fixture = try loadFixture()
        #expect(fixture.rules.count == 20)
        let set = ruleSet(fixture)
        let manifest = try JSONDecoder().decode([Utterance].self,
            from: Data(contentsOf: Self.data.appending(path: "librispeech-test-clean-manifest.json")))
        #expect(manifest.count == 50)
        for reference in manifest.map(\.reference) {
            for text in [reference, reference.lowercased()] {
                let result = set.apply(to: text)
                #expect(result.count == 0, "\(text)")
                #expect(result.text == text)
            }
        }
    }

    @Test("Kill criterion 1: Polish corpus changes only the positive controls")
    func polish() throws {
        let fixture = try loadFixture()
        #expect(fixture.polish.count >= 30)
        let set = ruleSet(fixture)
        for sentence in fixture.polish {
            #expect(set.apply(to: sentence.text).text == (sentence.expected ?? sentence.text), "\(sentence.text)")
        }
    }

    @Test("Every corpus rule is one the validator would offer")
    func corpusRulesOffered() throws {
        for pair in try loadFixture().rules {
            let assessment = ReplacementRuleValidator.assess(from: pair.from, to: pair.to, vocabulary: ["Plainsay"])
            #expect(assessment.isOffered, "\(pair.from) → \(pair.to): \(assessment)")
        }
    }

    /// Kill criterion 3 on macOS. `VoiceEditReview.details` includes NLTagger
    /// person/organization/place names; the validator must not. Whatever the
    /// tagger decides for these short inputs, every pair must still be offered.
    @Test("Kill criterion 3: NLTagger names never suppress a spelling fix")
    func nlTaggerDoesNotSuppress() {
        let pairs = [("jason", "JSON"), ("Kowalsky", "Kowalski"), ("plain say", "Plainsay"),
                     ("dżejson", "JSON"), ("Grzegosz", "Grzegorz"), ("lumen tar", "Lumenta")]
        for (from, to) in pairs {
            for (before, after) in [(from, to), ("Ask \(from) today", "Ask \(to) today")] {
                let tagged = VoiceEditReview(original: before, replacement: after).needsAttention
                let assessment = ReplacementRuleValidator.assess(from: before, to: after)
                // Diagnostic for the Mac run: shows where needsAttention would have over-suppressed.
                print("NLTAGGER \(before) → \(after): needsAttention=\(tagged) assess=\(assessment)")
                #expect(assessment.isOffered, "\(before) → \(after)")
            }
        }
    }

    @Test("Range helper matches the regex half of VoiceEditReview.details")
    func structuredDetailsParity() {
        let text = "Mail anna@x.pl, see https://jason.dev/a, pay $125 at 10:30 (3,5 %) — Kowalski."
        let spans = StructuredDetails.spans(in: text)
        #expect(spans.map(\.kind) == [.email, .url, .number, .number, .number])
        #expect(StructuredDetails.values(in: text) == ["anna@x.pl", "https://jason.dev/a", "$125", "10:30", "3,5 %"])
        #expect(StructuredDetails.values(in: text).isSubset(of: VoiceEditReview.details(in: text)))
        let ns = text as NSString
        #expect(ns.substring(with: spans[0].range) == "anna@x.pl")
    }

    @Test("Performance: 200 rules over 24,000 characters (spike measurement)")
    func performance() {
        let set = ReplacementRuleSet(rules: (0..<ReplacementRuleSet.limit).map {
            ReplacementRule(from: "projekt\($0) nazwa", to: "Projekt\($0)Nazwa")
        })
        let sentence = "Spotkajmy się we wtorek o 10:30, plik jason.txt i projekt7 nazwa są gotowe. "
        let text = String(repeating: sentence, count: 24_000 / sentence.count + 1)
        let clock = ContinuousClock()
        var result = (text: "", count: 0)
        let elapsed = clock.measure { result = set.apply(to: text) }
        print("REPLACEMENT_RULES_PERF rules=\(set.rules.count) chars=\(text.count) elapsed=\(elapsed)")
        #expect(result.count == 24_000 / sentence.count + 1)
        // The spec's 50 ms budget is unverified; this bound only catches a
        // pathological regression. Read the printed figure on the Mac run.
        #expect(elapsed < .seconds(2))
    }
}
