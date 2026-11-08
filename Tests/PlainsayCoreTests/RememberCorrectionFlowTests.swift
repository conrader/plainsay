import Foundation
import Testing
@testable import PlainsayCore

// remember-correction v1 (SPEC.fixed.md §4 tests 15–18, plus the save checks
// behind the confirmation card). Pure Core: no coordinator, no AppKit, so this
// file also runs in the Linux harness.

@MainActor
private final class RecordingTarget: DictationReplacementTarget {
    let replacedText: String
    var error: Error?
    private(set) var received: [String] = []
    init(_ text: String) { replacedText = text }
    func replace(with text: String) async throws {
        if let error { throw error }
        received.append(text)
    }
}

@Suite("Remember correction: matched phrase")
struct MatchedPhraseTests {
    @Test("15. The matched surface text is returned, with localReplacement's errors")
    func matchedSurface() throws {
        let command = try DictationCorrectionCommand.parse("change plain say to Plainsay")
        #expect(try command.matchedPhrase(in: "Plain Say rocks") == "Plain Say")
        #expect(throws: DictationCorrectionError.noMatch) { try command.matchedPhrase(in: "Nothing here") }
        #expect(throws: DictationCorrectionError.ambiguousMatch) {
            try command.matchedPhrase(in: "plain say and Plain Say")
        }
        #expect(try DictationCorrectionCommand.undo.matchedPhrase(in: "Plain Say") == nil)
        #expect(try DictationCorrectionCommand.rewrite("shorter").matchedPhrase(in: "Plain Say") == nil)
    }

    @Test("15. Numeric guards are shared with localReplacement")
    func numericGuard() throws {
        let command = DictationCorrectionCommand.replace("10", "11")
        #expect(throws: DictationCorrectionError.noMatch) { try command.matchedPhrase(in: "Meet at 10:30.") }
        #expect(try command.matchedPhrase(in: "Bring 10 chairs.") == "10")
        #expect(try command.localReplacement(in: "Bring 10 chairs.", undoText: nil) == "Bring 11 chairs.")
    }

    @Test("16. Polish command: Zamień dżejson na JSON. is offered with the surface form")
    func polishCommand() throws {
        let command = try DictationCorrectionCommand.parse("Zamień dżejson na JSON.")
        #expect(command == .replace("dżejson", "JSON"))
        let matched = try command.matchedPhrase(in: "Wyślij plik Dżejson jutro.")
        #expect(matched == "Dżejson")
        let offer = RememberCorrectionOffer.make(command: command, matched: matched, applied: true, isUndo: false,
                                                 rules: ReplacementRuleSet(), vocabulary: ["Plainsay"])
        #expect(offer == .remember(from: "Dżejson", to: "JSON", warning: nil))
    }
}

@Suite("Remember correction: offer after a verified apply")
@MainActor
struct RememberCorrectionApplyTests {
    /// The window's sequence: matched text read at preview, offer built only
    /// when `LastDictation.apply` returned without throwing.
    private func offerAfterApply(_ instruction: String, text: String, target: RecordingTarget?,
                                 rules: ReplacementRuleSet = ReplacementRuleSet()) async throws -> RememberCorrectionOffer? {
        let dictation = LastDictation(text: text, target: target)
        let command = try DictationCorrectionCommand.parse(instruction)
        let matched = try? command.matchedPhrase(in: dictation.text)
        let replacement = try #require(try command.localReplacement(in: dictation.text, undoText: dictation.undoText))
        let proposal = dictation.proposal(replacement: replacement, isUndo: command == .undo)
        var applied = false
        do {
            try await dictation.apply(proposal)
            applied = true
        } catch {}
        return RememberCorrectionOffer.make(command: command, matched: matched, applied: applied,
                                            isUndo: proposal.isUndo, rules: rules, vocabulary: [])
    }

    @Test("17. Offered after a successful replace; not after Copy only, a thrown target error, undo or a fact")
    func gating() async throws {
        let ok = RecordingTarget("Send the jason file.")
        #expect(try await offerAfterApply("change jason to JSON", text: "Send the jason file.", target: ok)
            == .remember(from: "jason", to: "JSON", warning: nil))
        #expect(ok.received == ["Send the JSON file."])

        // Copy only: no verified anchor, so apply throws `.stale`.
        #expect(try await offerAfterApply("change jason to JSON", text: "Send the jason file.", target: nil) == nil)

        let failing = RecordingTarget("Send the jason file.")
        failing.error = DictationCorrectionError.unverified
        #expect(try await offerAfterApply("change jason to JSON", text: "Send the jason file.", target: failing) == nil)

        let undo = RecordingTarget("Before.")
        #expect(try await offerAfterApply("undo that", text: "After.", target: undo) == nil)

        let fact = RecordingTarget("Meet on Tuesday.")
        #expect(try await offerAfterApply("change Tuesday to Thursday", text: "Meet on Tuesday.", target: fact) == nil)
        #expect(fact.received == ["Meet on Thursday."])
    }

    @Test("18. Correcting a rule's output back offers Turn off, which disables the rule")
    func inverseTurnOff() async throws {
        let rule = ReplacementRule(from: "jason", to: "JSON")
        var rules = ReplacementRuleSet(rules: [rule])
        let offer = try await offerAfterApply("change JSON to jason", text: "Send the JSON file.",
                                              target: RecordingTarget("Send the JSON file."), rules: rules)
        #expect(offer == .inverse(rule))
        rules.setEnabled(false, id: rule.id)
        #expect(rules.rules.first?.isEnabled == false)
        #expect(rules.apply(to: "Send the jason file.").count == 0)
    }
}

@Suite("Remember correction: saving an edited rule")
struct ReplacementRuleSaveTests {
    @Test("A plain spelling fix is ready and saves whitespace-normalized, enabled, newest first")
    func readyAndSave() throws {
        var rules = ReplacementRuleSet()
        #expect(rules.saveCheck(from: "Kowalsky", to: "Kowalski", vocabulary: []) == .ready)
        let old = Date(timeIntervalSince1970: 1_000)
        let savedFirst = rules.save(from: "  lumen   tar ", to: "Lumenta", source: .correction,
                                    vocabulary: [], now: old)
        let first = try #require(savedFirst)
        #expect(first.from == "lumen tar")
        #expect(first.isEnabled && first.source == .correction)
        let savedSecond = rules.save(from: "Kowalsky", to: "Kowalski", source: .correction, vocabulary: [])
        let second = try #require(savedSecond)
        #expect(rules.newestFirst.map(\.id) == [second.id, first.id])
        #expect(rules.apply(to: "Ask Kowalsky about lumen tar.").text == "Ask Kowalski about Lumenta.")
    }

    @Test("Rejections are returned and nothing is written")
    func rejected() {
        var rules = ReplacementRuleSet()
        #expect(rules.saveCheck(from: "Claude", to: "Claude Code", vocabulary: []) == .rejected(.containsFrom))
        #expect(rules.saveCheck(from: "jason", to: "jason", vocabulary: []) == .rejected(.identical))
        #expect(rules.saveCheck(from: " ", to: "JSON", vocabulary: []) == .rejected(.empty))
        #expect(rules.saveCheck(from: "jason", to: "JSON", vocabulary: ["Jason"]) == .rejected(.vocabularyTerm))
        #expect(rules.save(from: "Claude", to: "Claude Code", source: .correction, vocabulary: []) == nil)
        #expect(rules.rules.isEmpty)
    }

    @Test("Factual and common-word pairs need a confirmation instead of being blocked")
    func cautions() {
        let rules = ReplacementRuleSet()
        #expect(rules.saveCheck(from: "Tuesday", to: "Thursday", vocabulary: [])
            == .needsConfirmation(caution: .date, replaces: nil))
        #expect(rules.saveCheck(from: "$125", to: "$150", vocabulary: [])
            == .needsConfirmation(caution: .structuredDetail, replaces: nil))
        #expect(rules.saveCheck(from: "the", to: "a", vocabulary: [])
            == .needsConfirmation(caution: .commonWord, replaces: nil))
    }

    @Test("A different rule for the same phrase asks before replacing; the same target does not")
    func duplicate() throws {
        let existing = ReplacementRule(from: "jason", to: "Jason")
        var rules = ReplacementRuleSet(rules: [existing])
        #expect(rules.saveCheck(from: "Jason", to: "JSON", vocabulary: [])
            == .needsConfirmation(caution: nil, replaces: existing))
        #expect(rules.saveCheck(from: "jason", to: "Jason", vocabulary: []) == .ready)
        let result = rules.save(from: "Jason", to: "JSON", source: .correction, vocabulary: [])
        let saved = try #require(result)
        #expect(rules.rules == [saved])
    }

    @Test("At the limit a new phrase is rejected, but replacing an existing one still works")
    func limit() throws {
        var rules = ReplacementRuleSet(rules: (0..<ReplacementRuleSet.limit).map {
            ReplacementRule(from: "word\($0)x", to: "Word\($0)X")
        })
        #expect(rules.saveCheck(from: "Kowalsky", to: "Kowalski", vocabulary: []) == .rejected(.limitReached))
        #expect(rules.save(from: "Kowalsky", to: "Kowalski", source: .correction, vocabulary: []) == nil)
        #expect(rules.save(from: "word7x", to: "W7X", source: .correction, vocabulary: []) != nil)
        #expect(rules.rules.count == ReplacementRuleSet.limit)
    }

    @Test("Rule targets and Vocabulary membership compare folded keys")
    func folding() {
        let rules = ReplacementRuleSet(rules: [
            ReplacementRule(from: "jason", to: "JSON"),
            ReplacementRule(from: "lumen tar", to: "Lumenta", isEnabled: false),
        ])
        #expect(rules.hasTarget(matching: "json"))
        #expect(!rules.hasTarget(matching: "Lumenta"))
        #expect(!rules.hasTarget(matching: "--"))
        #expect(ReplacementRuleSet.vocabulary(["Plainsay"], contains: "plain say"))
        #expect(ReplacementRuleSet.vocabulary(["Kraków"], contains: "krakow"))
        #expect(!ReplacementRuleSet.vocabulary(["Plainsay"], contains: "Kowalski"))
    }
}
