import Foundation

/// What the confirmation card (or a later manual Add) must do before a pair
/// typed or edited by the user becomes a rule. Pure, so the App views stay thin
/// and the decisions are covered by `PlainsayCoreTests`.
public enum ReplacementRuleSaveCheck: Sendable, Equatable {
    /// Save as is.
    case ready
    /// Not saveable; the reason is shown and nothing is written.
    case rejected(ReplacementRejection)
    /// Saveable after the user confirms. `caution` is a factual or
    /// common-word pair the offer would never have suggested; `replaces` is an
    /// existing rule for the same `from` with a different `to`.
    case needsConfirmation(caution: ReplacementSuppression?, replaces: ReplacementRule?)
}

extension ReplacementRuleSet {
    /// Re-runs the validator on the edited text. `.suppressOffer` only blocks
    /// the *offer*: once the user has chosen to save, it becomes a
    /// confirmation (SPEC §2.5, "allowed after a confirmation").
    public func saveCheck(from: String, to: String, vocabulary: [String]) -> ReplacementRuleSaveCheck {
        let caution: ReplacementSuppression?
        switch ReplacementRuleValidator.assess(from: from, to: to, rules: self, vocabulary: vocabulary) {
        case .reject(let reason): return .rejected(reason)
        case .suppressOffer(let why): caution = why
        case .offer, .offerWithWarning: caution = nil
        }
        let to = ReplacementRuleValidator.normalized(to)
        let existing = rule(forFrom: from).flatMap { $0.to == to ? nil : $0 }
        if caution == nil, existing == nil { return .ready }
        return .needsConfirmation(caution: caution, replaces: existing)
    }

    /// Writes the pair (whitespace-normalized) as an enabled rule, replacing
    /// any rule with the same `from`. Call only after `saveCheck` allowed it.
    /// Returns nil, changing nothing, when the pair is not saveable.
    @discardableResult
    public mutating func save(from: String, to: String, source: ReplacementRule.Source,
                              vocabulary: [String], now: Date = Date()) -> ReplacementRule? {
        if case .rejected = saveCheck(from: from, to: to, vocabulary: vocabulary) { return nil }
        let rule = ReplacementRule(from: ReplacementRuleValidator.normalized(from),
                                   to: ReplacementRuleValidator.normalized(to),
                                   source: source, createdAt: now)
        return upsert(rule) ? rule : nil
    }

    /// Rules newest first, for the Settings list.
    public var newestFirst: [ReplacementRule] {
        rules.sorted { $0.createdAt > $1.createdAt }
    }

    /// Whether an enabled rule writes `term`, as its whole target or as one
    /// word of it (folded as `TermDictionary` folds terms). The Vocabulary
    /// proposer skips these: History holds post-rule text, so a rule target
    /// would otherwise come back as a Vocabulary suggestion and, if accepted,
    /// leave the Mac in speech and Polishing hints. The proposer offers single
    /// words, so `Kubernetes Engine` must also exclude `Kubernetes` and
    /// `Engine`; targets are split exactly as the proposer splits History.
    public func hasTarget(matching term: String) -> Bool {
        let key = TermDictionary.foldedKey(term)
        guard !key.isEmpty else { return false }
        return rules.contains { rule in
            guard rule.isEnabled else { return false }
            if TermDictionary.foldedKey(rule.to) == key { return true }
            return DictionaryProposer.words(in: rule.to).contains { TermDictionary.foldedKey($0) == key }
        }
    }

    /// Whether `term` is already in `vocabulary`, compared by folded key. The
    /// confirmation hides "Also add to Vocabulary" then (SPEC §2.4).
    public static func vocabulary(_ vocabulary: [String], contains term: String) -> Bool {
        let key = TermDictionary.foldedKey(term)
        return !key.isEmpty && vocabulary.contains { TermDictionary.foldedKey($0) == key }
    }
}
