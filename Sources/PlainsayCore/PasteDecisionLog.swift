import Foundation

/// The one line per dictation that says whether it was pasted, and why.
///
/// Written at default level so it is still in the unified log when someone
/// reports "it did not paste" hours later; info and debug lines are gone by
/// then. Takes no dictated text, so it cannot leak any:
/// `log show --predicate 'subsystem == "com.plainsay.dictation" AND category == "insertion"'`.
enum PasteDecisionLog {
    static func message(
        outcome: TextInsertionOutcome,
        report: PasteTargetReport?,
        targetBundleIdentifier: String?,
        frontmostBundleIdentifier: String?,
        keepOnClipboardSetting: Bool
    ) -> String {
        let decision: String
        let reason: String
        switch outcome {
        case .inserted, .insertedUnconfirmed:
            decision = "paste"
            reason = report?.reason ?? "noTarget"
        case .noFocusedElement:
            decision = "keepOnClipboard"
            reason = "nothingFocused"
        case .targetUnavailable(let loss):
            decision = "keepOnClipboard"
            reason = loss.rawValue
        }
        let frontmost = report?.frontmostBundleIdentifier ?? frontmostBundleIdentifier
        return "paste decision=\(decision) reason=\(reason)"
            + " target=\(targetBundleIdentifier ?? "none")"
            + " reactivationAttempted=\(report?.reactivationAttempted ?? false)"
            + " frontmost=\(frontmost ?? "unknown")"
    }
}
