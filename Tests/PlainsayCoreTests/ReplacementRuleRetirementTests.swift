import Foundation
import Testing
@testable import PlainsayCore

// Vocabulary proposals never offer what a rule wrote into History, even after
// the rule was disabled, deleted or retargeted. Pure Core.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let grace = ReplacementRuleSet.retirementGrace

private func record(_ text: String, at date: Date) -> TranscriptRecord {
    TranscriptRecord(date: date, text: text, rawText: text, outcome: .inserted, durationSeconds: 4, targetApp: nil)
}

/// What Settings → Vocabulary offers for `history` under `rules`.
private func offered(_ history: [TranscriptRecord], _ rules: ReplacementRuleSet) -> Set<String> {
    Set(rules.excludingTargets(from: DictionaryProposer.propose(from: history)).map(\.term))
}

/// Two dictations the rule `lumen tar → Lumenta Studio` wrote, plus a real term.
private func ruledHistory(at date: Date = t0) -> [TranscriptRecord] {
    [record("We ship Lumenta Studio with Plainsay.", at: date),
     record("Ask Plainsay about Lumenta Studio.", at: date)]
}

@Suite("Replacement rules: retired targets")
struct ReplacementRuleRetirementTests {
    let lumenta = ReplacementRule(from: "lumen tar", to: "Lumenta Studio")

    @Test("Without exclusion the rule target would be proposed")
    func baseline() {
        #expect(offered(ruledHistory(), ReplacementRuleSet()) == ["Lumenta", "Studio", "Plainsay"])
    }

    @Test("A disabled rule's target is not proposed")
    func disabled() {
        var rules = ReplacementRuleSet(rules: [lumenta])
        rules.setEnabled(false, id: lumenta.id)
        #expect(offered(ruledHistory(), rules) == ["Plainsay"])
        rules.isEnabled = false
        #expect(offered(ruledHistory(), rules) == ["Plainsay"])
    }

    @Test("A deleted rule's target is retired and not proposed")
    func deleted() {
        var rules = ReplacementRuleSet(rules: [lumenta])
        rules.remove(id: lumenta.id, now: t0)
        #expect(rules.rules.isEmpty)
        #expect(rules.retiredTargets == [RetiredRuleTarget(to: "Lumenta Studio", retiredAt: t0)])
        #expect(offered(ruledHistory(), rules) == ["Plainsay"])
    }

    @Test("A changed target retires the old one; both stay excluded")
    func retargeted() {
        var rules = ReplacementRuleSet(rules: [lumenta])
        rules.upsert(ReplacementRule(from: "lumen tar", to: "Lumentum"), now: t0)
        #expect(rules.retiredTargets.map(\.to) == ["Lumenta Studio"])
        #expect(offered(ruledHistory(), rules) == ["Plainsay"])
        #expect(rules.hasTarget(matching: "Lumentum"))
        // Saving the same target again retires nothing.
        rules.upsert(ReplacementRule(from: "Lumen Tar", to: "Lumentum"), now: t0)
        #expect(rules.retiredTargets.count == 1)
        // `save` goes through `upsert` with its own clock.
        _ = rules.save(from: "lumen tar", to: "Lumenta Pro", source: .manual, vocabulary: [], now: t0 + 5)
        #expect(rules.retiredTargets.map(\.to) == ["Lumenta Studio", "Lumentum"])
    }

    @Test("A dictation that froze the rule and records after it was disabled or deleted proposes nothing of it")
    func inFlightSnapshot() {
        var live = ReplacementRuleSet(rules: [lumenta, ReplacementRule(from: "kubernetis", to: "Kubernetes")])
        let snapshot = live                      // DictationSessionPolicy freezes this at recording start
        live.setEnabled(false, id: lumenta.id)   // edited while the dictation is still running
        live.remove(id: live.rules[1].id, now: t0)
        let written = snapshot.apply(to: "we ship lumen tar on kubernetis daily").text
        #expect(written == "we ship Lumenta Studio on Kubernetes daily")
        let history = [record(written, at: t0 + 300), record(written, at: t0 + 600)]
        #expect(offered(history, ReplacementRuleSet()) == ["Lumenta", "Studio", "Kubernetes"])
        #expect(offered(history, live).isEmpty)
        // The grace keeps the retired target even while History is still empty.
        #expect(live.pruningRetiredTargets(history: [], now: t0 + 600).retiredTargets.count == 1)
    }

    @Test("A retired target is pruned only when History can no longer hold its text")
    func pruning() {
        var rules = ReplacementRuleSet(rules: [lumenta])
        rules.remove(id: lumenta.id, now: t0)
        let old = record("Lumenta Studio", at: t0 + grace - 1)
        let newer = record("Plainsay", at: t0 + grace + 1)
        let later = t0 + grace + 10
        // Inside the grace: kept, whatever History holds.
        #expect(rules.pruningRetiredTargets(history: [], now: t0 + grace).retiredTargets.count == 1)
        // A record old enough to carry the rule's output: kept.
        #expect(rules.pruningRetiredTargets(history: [newer, old], now: later).retiredTargets.count == 1)
        // Only newer records left (retention removed the rest): pruned.
        #expect(rules.pruningRetiredTargets(history: [newer], now: later).retiredTargets.isEmpty)
        #expect(rules.pruningRetiredTargets(history: [], now: later).retiredTargets.isEmpty)
        // Pruning never touches rules.
        let live = ReplacementRuleSet(rules: [lumenta])
        #expect(live.pruningRetiredTargets(history: [], now: later) == live)
    }

    @Test("Retiring the same target again keeps one entry with the newest date; the list is bounded")
    func bounded() {
        var rules = ReplacementRuleSet()
        rules.retire("Lumenta Studio", now: t0)
        rules.retire("lumenta  studio", now: t0 + 1)
        #expect(rules.retiredTargets == [RetiredRuleTarget(to: "lumenta  studio", retiredAt: t0 + 1)])
        for i in 0..<(ReplacementRuleSet.retiredLimit + 5) { rules.retire("Term\(i)x", now: t0 + Double(i)) }
        #expect(rules.retiredTargets.count == ReplacementRuleSet.retiredLimit)
        #expect(rules.retiredTargets.last?.to == "Term\(ReplacementRuleSet.retiredLimit + 4)x")
    }

    @Test("Retired targets persist; malformed or oversized entries are dropped on load")
    func persistence() throws {
        var rules = ReplacementRuleSet(rules: [lumenta])
        rules.remove(id: lumenta.id, now: t0)
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(ReplacementRuleSet.self, from: data) == rules)

        let long = String(repeating: "x", count: ReplacementRuleValidator.maxToLength + 1)
        let json = #"{"rules":[],"retiredTargets":[{"to":"Lumenta","retiredAt":1},{"to":"\#(long)","retiredAt":2},"#
            + #"{"to":"Lumentum"},{"to":"   ","retiredAt":3},{"to":"LUMENTA","retiredAt":4}]}"#
        let loaded = try JSONDecoder().decode(ReplacementRuleSet.self, from: Data(json.utf8))
        #expect(loaded.retiredTargets == [RetiredRuleTarget(to: "LUMENTA", retiredAt: Date(timeIntervalSinceReferenceDate: 4))])
        // Stored data from before retired targets existed still loads.
        let legacy = try JSONDecoder().decode(ReplacementRuleSet.self, from: Data(#"{"rules":[]}"#.utf8))
        #expect(legacy.retiredTargets.isEmpty)
    }
}
