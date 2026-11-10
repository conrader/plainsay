import Foundation

/// The target of a rule that was deleted or given a new target. History can
/// still hold text that rule wrote (it keeps post-rule text, and a dictation
/// that snapshotted the rule before the edit records it afterwards), so the
/// Vocabulary proposer keeps skipping the target until that text is gone.
/// Local data, stored with the rules; never sent anywhere.
public struct RetiredRuleTarget: Codable, Sendable, Equatable {
    public var to: String
    public var retiredAt: Date

    public init(to: String, retiredAt: Date) {
        self.to = to
        self.retiredAt = retiredAt
    }
}

extension ReplacementRuleSet {
    /// At most this many retired targets are kept, oldest dropped first.
    public static let retiredLimit = 200

    /// How long after retirement a dictation that froze the old rule set
    /// (SPEC.fixed.md §3.3) can still write to History: the 10-minute
    /// recording cap plus transcription and Polishing, rounded up generously.
    public static let retirementGrace: TimeInterval = 60 * 60

    /// Records `target` as retired now; an earlier entry for the same folded
    /// target is replaced, so the newest (longest-lived) date wins.
    mutating func retire(_ target: String, now: Date) {
        let key = TermDictionary.foldedKey(target)
        retiredTargets.removeAll { TermDictionary.foldedKey($0.to) == key }
        retiredTargets.append(RetiredRuleTarget(to: target, retiredAt: now))
        if retiredTargets.count > Self.retiredLimit {
            retiredTargets.removeFirst(retiredTargets.count - Self.retiredLimit)
        }
    }

    /// Whether a rule — enabled or not — or a retired target writes `term`,
    /// as its whole target or as one word of it (folded as `TermDictionary`
    /// folds terms). The Vocabulary proposer skips these: History holds
    /// post-rule text, so a rule target would otherwise come back as a
    /// Vocabulary suggestion and, if accepted, leave the Mac in speech and
    /// Polishing hints. Disabled rules count because History may hold text
    /// they wrote while enabled. The proposer offers single words, so
    /// `Kubernetes Engine` must also exclude `Kubernetes` and `Engine`;
    /// targets are split exactly as the proposer splits History.
    public func hasTarget(matching term: String) -> Bool {
        let key = TermDictionary.foldedKey(term)
        guard !key.isEmpty else { return false }
        func writes(_ target: String) -> Bool {
            TermDictionary.foldedKey(target) == key
                || DictionaryProposer.words(in: target).contains { TermDictionary.foldedKey($0) == key }
        }
        return rules.contains { writes($0.to) } || retiredTargets.contains { writes($0.to) }
    }

    /// `proposals` without any term a rule wrote or may have written.
    public func excludingTargets(from proposals: [DictionaryProposal]) -> [DictionaryProposal] {
        proposals.filter { !hasTarget(matching: $0.term) }
    }

    /// A copy without retired targets whose text can no longer be in
    /// History: the grace for in-flight dictations has passed and no
    /// retained record is old enough to have been written by the rule.
    /// Over-keeping only hides a proposal; under-keeping could leak a rule
    /// target into Vocabulary, so every doubt keeps the entry.
    public func pruningRetiredTargets(history: [TranscriptRecord], now: Date = Date()) -> ReplacementRuleSet {
        var copy = self
        copy.retiredTargets.removeAll { entry in
            let lastWrite = entry.retiredAt.addingTimeInterval(Self.retirementGrace)
            guard now > lastWrite else { return false }
            return !history.contains { $0.date <= lastWrite }
        }
        return copy
    }
}
