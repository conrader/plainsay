import Foundation

/// The normal insertion path and the headless eval share this final text step.
public func finalizeDictationText(_ text: String, rules: ReplacementRuleSet) -> String {
    sanitizeForInsertion(applyDictationReplacementRules(rules, to: text))
}

/// The live session uses rules frozen at recording start. Crash recovery uses the live settings.
func applyDictationReplacementRules(_ rules: ReplacementRuleSet, to text: String) -> String {
    let ruled = rules.apply(to: text)
    if ruled.count > 0 {
        Log.pipeline.info("applied \(ruled.count, privacy: .public) replacement rule(s)")
    }
    return ruled.text
}
