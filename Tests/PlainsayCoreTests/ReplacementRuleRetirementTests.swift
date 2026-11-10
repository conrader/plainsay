import Foundation
import Testing
@testable import PlainsayCore

// Vocabulary proposals never offer what a rule wrote into History, even after
// the rule was disabled, deleted or retargeted. Pure Core.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

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
        // While the dictation may still write, nothing is pruned, even with History empty.
        #expect(live.pruningRetiredTargets(history: [], workInFlight: true) == live)
    }

    @Test("A late write after the old one-hour bound is still excluded; pruning follows History, not time")
    func lateWrite() {
        var live = ReplacementRuleSet(rules: [lumenta])
        let snapshot = live
        live.remove(id: lumenta.id, now: t0)
        // Days later the frozen dictation is still running: prune keeps the entry.
        let days = t0 + 3 * 86_400
        live = live.pruningRetiredTargets(history: [], workInFlight: true)
        #expect(live.retiredTargets.count == 1)
        // It completes and writes the old target, dated well after retirement.
        let late = record(snapshot.apply(to: "lumen tar again").text, at: days + 1)
        let history = [late, record("Ask about Lumenta Studio", at: days + 2)]
        live = live.pruningRetiredTargets(history: history, workInFlight: false)
        #expect(live.retiredTargets.map(\.to) == ["Lumenta Studio"])
        #expect(offered(history, live).isEmpty)
        // One word of the target left in History is enough to keep it.
        let partial = [record("Lumenta only", at: days + 3)]
        #expect(live.pruningRetiredTargets(history: partial, workInFlight: false).retiredTargets.count == 1)
    }

    @Test("A retired target is pruned only after History no longer holds any of its words")
    func pruning() {
        var rules = ReplacementRuleSet(rules: [lumenta])
        rules.remove(id: lumenta.id, now: t0)
        let holds = record("We ship Lumenta Studio", at: t0 - 100)   // dated before retirement
        let other = record("Plainsay", at: t0 + 100)
        #expect(rules.pruningRetiredTargets(history: [other, holds], workInFlight: false).retiredTargets.count == 1)
        // Folding matches the proposer: case and diacritics do not hide the text.
        let folded = record("lumentá", at: t0 + 1)
        #expect(rules.pruningRetiredTargets(history: [folded], workInFlight: false).retiredTargets.count == 1)
        // Retention removed it: pruned at once, with no grace period.
        #expect(rules.pruningRetiredTargets(history: [other], workInFlight: false).retiredTargets.isEmpty)
        #expect(rules.pruningRetiredTargets(history: [], workInFlight: false).retiredTargets.isEmpty)
        // Pruning never touches rules.
        let live = ReplacementRuleSet(rules: [lumenta])
        #expect(live.pruningRetiredTargets(history: [], workInFlight: false) == live)
    }

    @Test("Retiring the same target again keeps one entry with the newest date")
    func refreshed() {
        var rules = ReplacementRuleSet()
        rules.retire("Lumenta Studio", now: t0)
        rules.retire("lumenta  studio", now: t0 + 1)
        #expect(rules.retiredTargets == [RetiredRuleTarget(to: "lumenta  studio", retiredAt: t0 + 1)])
        #expect(rules.retiredOverflow == nil)
    }

    /// `lumenta` removed, then `retiredLimit` more retirements forget it.
    private func overflowed() -> ReplacementRuleSet {
        var rules = ReplacementRuleSet(rules: [lumenta])
        rules.remove(id: lumenta.id, now: t0)
        for i in 0..<ReplacementRuleSet.retiredLimit { rules.retire("Term\(i)x", now: t0 + Double(i + 1)) }
        return rules
    }

    @Test("Overflowing the retired list never reopens a forgotten target: proposals stay hidden until History drops it")
    func overflow() {
        let rules = overflowed()
        let limit = ReplacementRuleSet.retiredLimit
        #expect(rules.retiredTargets.count == limit)
        #expect(!rules.retiredTargets.contains { $0.to == "Lumenta Studio" })   // forgotten...
        #expect(rules.retiredOverflow == RetiredOverflow())
        let history = ruledHistory(at: t0 + 1_000)
        #expect(offered(history, rules).isEmpty)                                // ...but never offered
        // In flight: nothing settles or clears.
        #expect(rules.pruningRetiredTargets(history: [], workInFlight: true) == rules)
        #expect(rules.pruningRetiredTargets(history: history, workInFlight: true) == rules)
        // First quiet prune settles on the records present; they keep the fallback.
        var pruned = rules.pruningRetiredTargets(history: history, workInFlight: false)
        #expect(pruned.retiredOverflow == RetiredOverflow(pendingRecords: history.map(\.id)))
        #expect(pruned.retiredTargets.isEmpty)        // known targets follow their own History check
        #expect(offered(history, pruned).isEmpty)
        // A newer record does not clear it while an old one remains, and is not added...
        let newer = record("Ask Plainsay about Lumenta Studio.", at: t0 + 2_000)
        pruned = pruned.pruningRetiredTargets(history: [newer] + history, workInFlight: false)
        #expect(pruned.retiredOverflow == RetiredOverflow(pendingRecords: history.map(\.id)))
        // ...retention removing one shrinks the set...
        pruned = pruned.pruningRetiredTargets(history: [newer, history[1]], workInFlight: false)
        #expect(pruned.retiredOverflow == RetiredOverflow(pendingRecords: [history[1].id]))
        #expect(offered([newer, history[1]], pruned).isEmpty)
        // ...and removing every settled record clears it, whatever their dates.
        pruned = pruned.pruningRetiredTargets(history: [newer], workInFlight: false)
        #expect(pruned.retiredOverflow == nil)
        // A further overflow resets settling.
        for i in 0...limit { pruned.retire("More\(i)x", now: t0 + 3_000) }
        #expect(pruned.retiredOverflow == RetiredOverflow())
        // An empty History settles and clears at once.
        #expect(rules.pruningRetiredTargets(history: [], workInFlight: false).retiredOverflow == nil)
    }

    @Test("Clock rollback: History dated after the prune still holds the overflow (reviewer counterexample)")
    func overflowClockRollback() {
        let rules = overflowed()
        // Records written at t0 + 1000; the clock is then set back and the prune runs "at" t0.
        let history = ruledHistory(at: t0 + 1_000)
        let pruned = rules.pruningRetiredTargets(history: history, workInFlight: false)
        #expect(pruned.retiredOverflow != nil)
        #expect(!pruned.retiredTargets.contains { $0.to == "Lumenta Studio" })
        #expect(offered(history, pruned).isEmpty)
        // A second prune, and a reload, keep it while either record remains.
        let again = pruned.pruningRetiredTargets(history: history, workInFlight: false)
        #expect(again == pruned && offered(history, again).isEmpty)
        let reloaded = try? JSONDecoder().decode(ReplacementRuleSet.self, from: JSONEncoder().encode(again))
        #expect(reloaded == again)
        // Clock jumped forward instead: records dated in the far past still hold it.
        let old = ruledHistory(at: t0 - 1_000_000)
        #expect(offered(old, rules.pruningRetiredTargets(history: old, workInFlight: false)).isEmpty)
    }

    @Test("Stored lists longer than the limit, or a bad overflow marker, load as an unsettled overflow")
    func overflowOnLoad() throws {
        let limit = ReplacementRuleSet.retiredLimit
        func json(_ count: Int, extra: String = "") -> Data {
            let items = (0..<count).map { #"{"to":"T\#($0)x","retiredAt":\#($0)}"# }.joined(separator: ",")
            return Data(#"{"rules":[],"retiredTargets":[\#(items)]\#(extra)}"#.utf8)
        }
        let full = try JSONDecoder().decode(ReplacementRuleSet.self, from: json(limit))
        #expect(full.retiredTargets.count == limit && full.retiredOverflow == nil)
        let over = try JSONDecoder().decode(ReplacementRuleSet.self, from: json(limit + 1))
        #expect(over.retiredTargets.count == limit && over.retiredOverflow == RetiredOverflow())
        #expect(over.retiredTargets.last?.to == "T\(limit)x")
        // Elements past the decode bound were never read: same fallback, even with one distinct target.
        let same = Array(repeating: #"{"to":"Lumenta","retiredAt":1}"#, count: ReplacementRuleSet.rawElementLimit + 1)
        let truncated = try JSONDecoder().decode(ReplacementRuleSet.self,
            from: Data(#"{"rules":[],"retiredTargets":[\#(same.joined(separator: ","))]}"#.utf8))
        #expect(truncated.retiredTargets.count == 1 && truncated.retiredOverflow == RetiredOverflow())
        let bad = try JSONDecoder().decode(ReplacementRuleSet.self, from: json(1, extra: #","retiredOverflow":7"#))
        #expect(bad.retiredOverflow == RetiredOverflow())
        // The marker round-trips.
        var settled = full
        settled.retiredOverflow = RetiredOverflow(pendingRecords: [UUID(), UUID()])
        #expect(try JSONDecoder().decode(ReplacementRuleSet.self, from: JSONEncoder().encode(settled)) == settled)
        // A date-based marker from the earlier build, a bad id, or too many ids load unsettled.
        let dated = try JSONDecoder().decode(ReplacementRuleSet.self, from: json(1, extra: #","retiredOverflow":{"settledAt":5}"#))
        #expect(dated.retiredOverflow == RetiredOverflow())
        let badID = try JSONDecoder().decode(ReplacementRuleSet.self,
            from: json(1, extra: #","retiredOverflow":{"pendingRecords":["\#(UUID().uuidString)","nope"]}"#))
        #expect(badID.retiredOverflow == RetiredOverflow())
        let ids = (0...RetiredOverflow.pendingLimit).map { _ in "\"\(UUID().uuidString)\"" }.joined(separator: ",")
        let many = try JSONDecoder().decode(ReplacementRuleSet.self,
            from: json(1, extra: #","retiredOverflow":{"pendingRecords":[\#(ids)]}"#))
        #expect(many.retiredOverflow == RetiredOverflow())
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
