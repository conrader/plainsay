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

/// Set when a retired target had to be forgotten (the list was full, or a
/// stored list was longer than `retiredLimit`). The forgotten target may
/// still be in History, so while this is set no History-derived Vocabulary
/// proposal is offered at all. `settledAt` is the first prune at which no
/// dictation could still write History: every record a forgotten rule wrote
/// is then dated at or before it, so the flag clears once History holds no
/// record that old.
public struct RetiredOverflow: Codable, Sendable, Equatable {
    public var settledAt: Date?

    public init(settledAt: Date? = nil) { self.settledAt = settledAt }
}

extension ReplacementRuleSet {
    /// At most this many retired targets are kept. Forgetting one more sets
    /// `retiredOverflow` instead of silently reopening its exclusion.
    public static let retiredLimit = 200

    /// Records `target` as retired now; an earlier entry for the same folded
    /// target is replaced, so the newest date wins.
    mutating func retire(_ target: String, now: Date) {
        let key = TermDictionary.foldedKey(target)
        retiredTargets.removeAll { TermDictionary.foldedKey($0.to) == key }
        retiredTargets.append(RetiredRuleTarget(to: target, retiredAt: now))
        if retiredTargets.count > Self.retiredLimit {
            retiredTargets.removeFirst(retiredTargets.count - Self.retiredLimit)
            retiredOverflow = RetiredOverflow()   // a new unknown; any earlier settling no longer holds
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
        return rules.contains { Self.targetKeys($0.to).contains(key) }
            || retiredTargets.contains { Self.targetKeys($0.to).contains(key) }
    }

    /// `proposals` without any term a rule wrote or may have written. Empty
    /// while `retiredOverflow` is set: a forgotten target cannot be named.
    public func excludingTargets(from proposals: [DictionaryProposal]) -> [DictionaryProposal] {
        guard retiredOverflow == nil else { return [] }
        return proposals.filter { !hasTarget(matching: $0.term) }
    }

    /// A copy without retired targets whose text can no longer reach the
    /// proposer. Nothing changes while `workInFlight` (a dictation or
    /// correction that may still write History from a rule set frozen before
    /// the retirement; `DictationCoordinator.mayStillWriteHistory`). Otherwise
    /// every rule snapshot that held the retired rule has finished writing,
    /// later dictations froze sets without it, and recovery uses the live set,
    /// so History is the only place its output can be: an entry is kept while
    /// any retained record contains its whole target or one of its words, by
    /// the same split and folding as `hasTarget`, and pruned once retention
    /// has removed them all. No time bound is assumed. Over-keeping only
    /// hides a proposal; every doubt keeps the entry.
    public func pruningRetiredTargets(history: [TranscriptRecord], workInFlight: Bool,
                                      now: Date = Date()) -> ReplacementRuleSet {
        guard !workInFlight else { return self }
        var present = Set<String>()
        for record in history {
            present.insert(TermDictionary.foldedKey(record.text))
            for word in DictionaryProposer.words(in: record.text) { present.insert(TermDictionary.foldedKey(word)) }
        }
        var copy = self
        copy.retiredTargets.removeAll { Self.targetKeys($0.to).isDisjoint(with: present) }
        if var overflow = copy.retiredOverflow {
            let settledAt = overflow.settledAt ?? now
            overflow.settledAt = settledAt
            copy.retiredOverflow = history.contains { $0.date <= settledAt } ? overflow : nil
        }
        return copy
    }

    /// The folded whole target and its folded words, as `hasTarget` matches.
    static func targetKeys(_ target: String) -> Set<String> {
        var keys = Set(DictionaryProposer.words(in: target).map(TermDictionary.foldedKey))
        keys.insert(TermDictionary.foldedKey(target))
        keys.remove("")
        return keys
    }
}
