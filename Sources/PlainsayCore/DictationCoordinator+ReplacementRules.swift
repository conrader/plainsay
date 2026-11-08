import Foundation

/// Remember-correction rules in the pipeline (SPEC.fixed.md §2.3). The two
/// call sites live in `DictationCoordinator.swift`: after Polishing (or its
/// failure, or with it off) and before `sanitizeForInsertion` in
/// `runPipeline`, and after `clean` in crash recovery. Correction-command
/// capture, voice-edit rewrites and live preview never come through here.
extension DictationCoordinator {
    /// Read live from settings. Snapshotting rules into the session policy at
    /// recording start is app-profiles follow-up work, not part of v1.
    func applyReplacementRules(to text: String) -> String {
        let ruled = settings.replacementRules.apply(to: text)
        if ruled.count > 0 {
            // A count only: never the phrases or the text.
            Log.pipeline.info("applied \(ruled.count, privacy: .public) replacement rule(s)")
        }
        return ruled.text
    }
}
