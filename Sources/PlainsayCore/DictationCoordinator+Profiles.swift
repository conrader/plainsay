import Foundation

/// App profiles (FEATURES #4). The profile is resolved once, when recording
/// starts, into the frozen `sessionPolicy`; this file holds the reads that
/// turn it into a cleanup style, the HUD chip and the Cloud-refresh rule. The
/// hooks that apply the policy stay in the pipeline in
/// `DictationCoordinator.swift`.
extension DictationCoordinator {
    /// The global settings the session starts from, read once.
    func sessionDefaults() -> DictationDefaults {
        DictationDefaults(
            dictionary: settings.dictionary,
            cleanupEnabled: settings.cleanupEnabled,
            emailModeEnabled: settings.emailModeEnabled,
            translationTargetLanguage: settings.translationTargetLanguage
        )
    }

    /// The profile for the app captured at recording start. Correction
    /// capture keeps using global settings (spec §3 (h)).
    func resolvedProfile(forCorrection: Bool) -> DictationProfile? {
        guard !forCorrection else { return nil }
        return DictationProfileResolver.resolve(bundleIdentifier: targetBundleIdentifier, in: settings.appProfiles)
    }

    /// The layout and translation for this dictation.
    ///
    /// Layout and translation are resolved independently — an email dictated
    /// in Polish and sent in English is one dictation, not two features
    /// fighting over a single setting.
    ///
    /// Both are paid, and both are gated on the entitlement rather than on
    /// which engine runs: cleanup can happen on-device, so keying either off
    /// the transcription source would hand it to every local user for free.
    /// The entitlement is checked live here; what was *requested* (global
    /// settings or the app profile) is frozen in `policy` at recording start.
    func resolvedDictationStyle(for policy: DictationSessionPolicy) -> CleanupStyle {
        guard cloud.account?.isActive == true else { return .plain }
        return CleanupStyle(layout: resolvedLayout(for: policy), translateTo: policy.translateTo)
    }

    /// Whether this dictation should be laid out as an email.
    ///
    /// Checked cheapest-first: the requested layout, then the target app's
    /// identity, and only then its window title — reading another app's title
    /// over Accessibility is the expensive step, and a browser is the only
    /// case that needs it. The title read stays at pipeline time.
    private func resolvedLayout(for policy: DictationSessionPolicy) -> DictationLayout {
        guard policy.emailLayoutEnabled, let bundleIdentifier = targetBundleIdentifier else { return .plain }
        if MailTarget.isComposer(bundleIdentifier: bundleIdentifier, windowTitle: nil) {
            return .email
        }
        return MailTarget.isComposer(bundleIdentifier: bundleIdentifier, windowTitle: targetWindowTitle())
            ? .email : .plain
    }

    /// Something in use needs a live Cloud account. Profiles count too:
    /// a profile asking for email layout or translation while the global
    /// controls are off would otherwise leave `cloud.account` nil after
    /// launch and silently produce plain text (the T-238 bug class).
    var needsCloudAccount: Bool {
        settings.transcriptionSource == .cloud
            || settings.cleanupProvider == .plainsay
            || settings.emailModeEnabled
            || settings.translationTargetLanguage != nil
            || settings.appProfiles.contains(where: \.requestsCloudEntitlement)
    }

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

    /// Call when the Profiles tab appears and whenever `appProfiles` changes,
    /// so a profile that newly requests a Cloud feature refreshes the account
    /// without a relaunch. No network call unless something needs Cloud and
    /// the user is signed in.
    public func appProfilesChanged() async {
        await refreshCloudCleanupIfNeeded()
    }

    /// `<Name> · <route>[ · → PL | · no translation]` while a non-Default
    /// profile's dictation is in flight; nil for Default, for a private
    /// session (its own badge states the route) and once the work unit ends.
    ///
    /// States what will actually run, not what was requested: Polishing and
    /// translation count only when `PolishingReadiness` says the cleaner is
    /// built (the rule `ProviderFactory.makeCleaner` uses). The global switch
    /// is read live, so turning Polishing off mid-recording — which the
    /// pipeline honours — changes the chip too. A requested translation that
    /// will not run says “no translation” rather than nothing.
    public var profileChip: String? {
        let policy = sessionPolicy
        guard policy.privacy == .standard, let name = policy.profileName else { return nil }
        let source = preparedSource ?? settings.transcriptionSource
        let polishes = policy.allowsCleanup && effectivePolishingReadiness().runs
        var parts = name.isEmpty ? [] : [name]
        parts.append(DictationProfileRoute.label(source: source, polishing: polishes,
                                                provider: settings.cleanupProvider))
        if let target = policy.translateTo, polishes, cloud.account?.isActive == true {
            parts.append("→ " + target.uppercased())
        } else if policy.translateTo != nil || policy.translationSuppressedByProfile {
            parts.append(Localization.coreString("hud.profile.noTranslation", fallback: "no translation"))
        }
        return parts.joined(separator: " · ")
    }

    /// Reads the Polishing key once per profiled dictation: the HUD redraws
    /// the chip 30 times a second while recording, too often for the Keychain.
    func captureChipKeyCheck() {
        guard sessionPolicy.profileName != nil else { chipKeyCheck = nil; return }
        let provider = settings.cleanupProvider
        chipKeyCheck = (provider, provider != .plainsay && !settings.apiKey(for: provider).isEmpty)
    }

    /// Live readiness, using the key presence captured at recording start
    /// unless the provider changed since (then the Keychain is read).
    func effectivePolishingReadiness() -> PolishingReadiness {
        let cached = chipKeyCheck.flatMap { $0.provider == settings.cleanupProvider ? $0.hasKey : nil }
        return ProviderFactory.polishingReadiness(settings, hasKey: cached)
    }
}

/// The route part of the HUD chip (SPEC.fixed §2.5), first match wins.
public enum DictationProfileRoute {
    public static func label(source: TranscriptionSource, polishing: Bool, provider: CleanupProvider) -> String {
        switch source {
        case .onDevice where !polishing:
            Localization.coreString("hud.profile.localOnly", fallback: "Local only")
        case .onDevice:
            Localization.coreFormat("hud.profile.polishing", fallback: "Polishing: %@", provider.displayName)
        case .remote:
            Localization.coreString("hud.profile.remoteSpeech", fallback: "Remote speech")
        case .cloud:
            Localization.coreString("hud.profile.cloud", fallback: "Cloud")
        }
    }
}
