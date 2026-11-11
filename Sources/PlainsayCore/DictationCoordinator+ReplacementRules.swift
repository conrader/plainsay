import Foundation

/// Remember-correction rules in the pipeline (SPEC.fixed.md §2.3). The two
/// call sites live in `DictationCoordinator.swift`: after Polishing (or its
/// failure, or with it off) and before `sanitizeForInsertion` in
/// `runPipeline`, and after `clean` in crash recovery. Correction-command
/// capture, voice-edit rewrites and live preview never come through here.
extension DictationCoordinator {
    /// A dictation passes `sessionPolicy.replacementRules`, the set frozen at
    /// recording start (SPEC.fixed.md §3.3), so a Settings edit made while
    /// recording or Polishing applies from the next dictation. Crash recovery
    /// has no session and passes the live settings.
    func applyReplacementRules(_ rules: ReplacementRuleSet, to text: String) -> String {
        let ruled = rules.apply(to: text)
        if ruled.count > 0 {
            // A count only: never the phrases or the text.
            Log.pipeline.info("applied \(ruled.count, privacy: .public) replacement rule(s)")
        }
        return ruled.text
    }
}
