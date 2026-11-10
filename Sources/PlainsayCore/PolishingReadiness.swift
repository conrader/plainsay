import Foundation

/// Whether Polishing — and with it email layout and translation, which run
/// inside the cleaner — can actually run with the current settings.
///
/// One rule for the three places that must agree: `ProviderFactory.makeCleaner`
/// (what runs), the profile editor (what it offers, SPEC.fixed §2.2) and the
/// HUD chip (what it claims, §2.5). Without it the editor offered translation
/// and the chip said “→ PL” while the factory quietly built `NoCleanup`.
public enum PolishingReadiness: Equatable, Sendable {
    /// The global Polishing switch is off.
    case off
    /// A bring-your-own-key provider is selected without its key.
    case missingKey(CleanupProvider)
    /// Plainsay is the provider but no live session token is loaded: signed
    /// out, unsubscribed, or simply not refreshed yet this launch.
    case needsSubscription
    case ready

    /// A cleaner other than `NoCleanup` is built right now.
    public var runs: Bool { self == .ready }

    /// Whether the profile editor offers email layout and translation. A
    /// missing subscription token still offers them: the account may only be
    /// unrefreshed, and the editor's Cloud footer explains it (same as the
    /// global email switch). Off or a missing key never can run, so neither
    /// offers a dead choice.
    public var offersStyles: Bool {
        switch self {
        case .ready, .needsSubscription: true
        case .off, .missingKey: false
        }
    }
}

extension ProviderFactory {
    /// Pure form of the rule, so it is tested without the Keychain.
    public nonisolated static func polishingReadiness(
        cleanupEnabled: Bool, provider: CleanupProvider, hasKey: Bool, cloudSessionToken: String?
    ) -> PolishingReadiness {
        guard cleanupEnabled else { return .off }
        if provider == .plainsay { return cloudSessionToken == nil ? .needsSubscription : .ready }
        // No key means no cleanup, rather than a failing call on every
        // dictation: the raw transcript is a fine outcome, an error is not.
        return hasKey ? .ready : .missingKey(provider)
    }

    /// The rule applied to live settings, exactly as `makeCleaner` applies it.
    /// Key presence comes from `PlainsaySettings.hasAPIKey(for:)`, which reads
    /// the Keychain once per provider and is cleared by every key write, so
    /// the callers that poll (the HUD chip, the profile editor) stay cheap and
    /// still follow a key added or removed mid-recording.
    public static func polishingReadiness(_ settings: PlainsaySettings) -> PolishingReadiness {
        let provider = settings.cleanupProvider
        let needsKey = settings.cleanupEnabled && provider != .plainsay
        return polishingReadiness(
            cleanupEnabled: settings.cleanupEnabled,
            provider: provider,
            hasKey: needsKey && settings.hasAPIKey(for: provider),
            cloudSessionToken: cloudSessionToken
        )
    }
}
