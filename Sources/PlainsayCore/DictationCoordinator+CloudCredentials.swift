import Foundation

// Cloud credential refresh stays outside the coordinator pipeline.
// Profile entitlement requests participate in the same live account gate.
extension DictationCoordinator {
    /// Confirms the hosted plan is actually active and puts the session token
    /// where `CloudTranscriptionEngine` and `CloudCleanupService` can find it.
    ///
    /// Called whenever something actually needs Cloud (`needsCloudAccount`):
    /// Cloud transcription, Plainsay picked as the Polishing provider, or
    /// either of the two features `resolvedDictationStyle(for:)` gates on the
    /// entitlement alone (email layout, translation, globally or in an app
    /// profile) rather than on which engine runs — so
    /// someone using on-device speech with a BYOK editing provider never
    /// causes a network call to the subscription service unless they also
    /// turned one of those on. Without this, `cloud.account` stays nil for
    /// that combination after a fresh launch, so an active subscriber's
    /// "Format dictation as an email" toggle silently produced plain text —
    /// see PROJECT_REVIEW.md P1 / T-238.
    func refreshCloudCredentialsIfNeeded() async {
        guard needsCloudAccount, cloud.isSignedIn else {
            ProviderFactory.cloudSessionToken = nil
            return
        }

        do {
            let account = try await cloud.refreshAccount()
            guard account.isActive else {
                ProviderFactory.cloudSessionToken = nil
                Log.model.info("Plainsay Cloud subscription is \(account.status, privacy: .public)")
                return
            }
            ProviderFactory.cloudSessionToken = cloud.sessionToken
            Log.model.info("Plainsay Cloud session token loaded into memory")
        } catch {
            ProviderFactory.cloudSessionToken = nil
            Log.model.error("Plainsay Cloud unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Refreshes Cloud credentials in memory to match `settings.cleanupProvider`
    /// without touching the speech engine — picking Plainsay as the Polishing
    /// provider doesn't warrant tearing down and reloading an unrelated
    /// on-device model, the way changing the transcription source does.
    public func refreshCloudCleanupIfNeeded() async {
        await refreshCloudCredentialsIfNeeded()
    }
}
