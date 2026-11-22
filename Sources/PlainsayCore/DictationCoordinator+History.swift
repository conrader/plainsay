import Foundation

// History settings and the persistent recovery readout.
extension DictationCoordinator {
    /// Persists after the HUD fades until a later insertion works or the user
    /// copies/dismisses the unresolved record. Derived from history so relaunch
    /// and History-window recovery cannot drift out of sync with the menu.
    public var lastInsertionNeedsManualPaste: Bool {
        history.hasUnacknowledgedInsertion
    }

    /// Pushes the stored history preferences into `history`. Call after
    /// changing either of them in Settings. Returns false if something that
    /// should now be deleted is still on disk; `history.deletionFailed` keeps
    /// saying so until `history.retryDeletion()` or a later change succeeds.
    @discardableResult
    public func applyHistoryPolicy() -> Bool {
        let applied = history.applyPolicy(isEnabled: settings.historyEnabled, maxAge: settings.historyMaxAge)
        if !applied { Log.history.error("history settings applied, but some stored dictations could not be deleted") }
        return applied
    }
}
