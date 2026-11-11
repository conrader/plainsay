import Foundation

// Moved verbatim out of DictationCoordinator.swift to keep that file from
// growing (oneshot/R1 line budget). Behaviour unchanged; only `private` became
// internal so the main file can still call it.
extension DictationCoordinator {
    /// Confirms the hosted plan is actually active and puts the session token
    /// where `CloudTranscriptionEngine` and `CloudCleanupService` can find it.
    ///
    /// Called whenever something actually needs Cloud: Cloud transcription,
    /// Plainsay picked as the Polishing provider, or either of the two
    /// features `resolvedDictationStyle()` gates on the entitlement alone
    /// (email layout, translation) rather than on which engine runs — so
    /// someone using on-device speech with a BYOK editing provider never
    /// causes a network call to the subscription service unless they also
    /// turned one of those on. Without this, `cloud.account` stays nil for
    /// that combination after a fresh launch, so an active subscriber's
    /// "Format dictation as an email" toggle silently produced plain text —
    /// see PROJECT_REVIEW.md P1 / T-238.
    func refreshCloudCredentialsIfNeeded() async {
        let needsCloud = settings.transcriptionSource == .cloud
            || settings.cleanupProvider == .plainsay
            || settings.emailModeEnabled
            || settings.translationTargetLanguage != nil
        guard needsCloud, cloud.isSignedIn else {
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
}
