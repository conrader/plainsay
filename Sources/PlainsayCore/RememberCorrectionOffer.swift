import Foundation

/// What the correction window may offer after a correction. Pure and in Core
/// because the only test target is `PlainsayCoreTests`; the App card is a view.
public enum RememberCorrectionOffer: Sendable, Equatable {
    /// "Remember this correction?" for the matched surface text → `to`.
    case remember(from: String, to: String, warning: ReplacementWarning?)
    /// The correction reverses this existing rule: "Turn that rule off?"
    case inverse(ReplacementRule)

    /// - Parameters:
    ///   - matched: the surface text the `.replace` command matched in the last
    ///     dictation (not the spoken wording), or nil if it was not found.
    ///   - applied: true only after `LastDictation.apply` succeeded against a
    ///     verified target. Copy correction, `.stale` and `.unverified` pass
    ///     false, so they never get an offer.
    ///   - vocabulary: global plus app-profile Vocabulary terms.
    public static func make(command: DictationCorrectionCommand, matched: String?, applied: Bool,
                            isUndo: Bool, rules: ReplacementRuleSet,
                            vocabulary: [String]) -> RememberCorrectionOffer? {
        guard applied, !isUndo, rules.isEnabled,
              case .replace(_, let to) = command, let matched else { return nil }
        if let rule = rules.inverse(of: matched, to) { return .inverse(rule) }
        switch ReplacementRuleValidator.assess(from: matched, to: to, rules: rules, vocabulary: vocabulary) {
        case .offer: return .remember(from: matched, to: to, warning: nil)
        case .offerWithWarning(let warning): return .remember(from: matched, to: to, warning: warning)
        case .suppressOffer, .reject: return nil
        }
    }
}
