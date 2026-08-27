import Foundation
import Observation

/// User preferences. The Gemini key is deliberately absent — it lives in the
/// Keychain, not in UserDefaults.
@MainActor
@Observable
public final class PlainsaySettings {
    public static let shared = PlainsaySettings()
    /// Stable completion marker. App updates must not bump this to force the
    /// assistant on someone who has already configured Plainsay; new options
    /// belong in Settings or an explicitly requested setup run.
    public static let currentOnboardingVersion = 1

    private let defaults: UserDefaults
    /// Captured before this instance can persist anything. Older releases did
    /// not have an onboarding marker, so an existing preference is the only
    /// durable signal that this is an update rather than a fresh install when
    /// one of the system permissions is currently missing.
    private let hadLegacyConfiguration: Bool

    public var binding: HotkeyBinding { didSet { persist(binding, .binding) } }
    public var hotkeyMode: HotkeyMode { didSet { persist(hotkeyMode, .hotkeyMode) } }
    public var model: OnDeviceModel { didSet { persist(model, .model) } }
    public var dictionary: TermDictionary { didSet { persist(dictionary, .dictionary) } }
    /// Proposed terms the user turned down, so the same suggestion is not
    /// offered again every time they open Settings.
    public var dismissedTermProposals: [String] {
        didSet { defaults.set(dismissedTermProposals, forKey: Key.dismissedTermProposals.rawValue) }
    }
    public var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled.rawValue) } }
    public var cleanupProvider: CleanupProvider { didSet { persist(cleanupProvider, .cleanupProvider) } }
    /// Empty means "use the provider's default".
    public var cleanupModel: String { didSet { defaults.set(cleanupModel, forKey: Key.cleanupModel.rawValue) } }
    public var cleanupBaseURL: String { didSet { defaults.set(cleanupBaseURL, forKey: Key.cleanupBaseURL.rawValue) } }

    public var transcriptionSource: TranscriptionSource { didSet { persist(transcriptionSource, .transcriptionSource) } }
    public var asrProvider: ASRProvider { didSet { persist(asrProvider, .asrProvider) } }
    public var asrModel: String { didSet { defaults.set(asrModel, forKey: Key.asrModel.rawValue) } }
    public var asrBaseURL: String { didSet { defaults.set(asrBaseURL, forKey: Key.asrBaseURL.rawValue) } }
    public var playFeedbackSounds: Bool { didSet { defaults.set(playFeedbackSounds, forKey: Key.playFeedbackSounds.rawValue) } }
    /// Whether dictations are written to disk at all.
    ///
    /// On by default, and that default is deliberate: pasting into another app
    /// is the one step Plainsay cannot verify, so history is what stands
    /// between a silently failed paste and having to say it all again. This
    /// switch is for people whose threat model outweighs that, not a hint that
    /// the default is wrong.
    /// Lay dictation out as an email when it is being written into one.
    ///
    /// A paid feature, and gated on the subscription rather than on which
    /// engine runs — cleanup can happen on-device, so gating by engine would
    /// hand it to every local user for free. Off by default: a mode that
    /// reformats text the speaker did not want reformatted is worse than no
    /// mode, so it is opted into rather than discovered by surprise.
    public var emailModeEnabled: Bool { didSet { defaults.set(emailModeEnabled, forKey: Key.emailModeEnabled.rawValue) } }
    /// Language code every dictation is translated into, or nil for none.
    ///
    /// Nil is off, and off is the default: silently translating what someone
    /// said is the most surprising thing this app could do, so it only happens
    /// once they have picked a target on purpose.
    ///
    /// Paid, gated on the Cloud entitlement — translation happens in the
    /// cleanup stage, which can run on-device, so gating by engine would give
    /// it away.
    public var translationTargetLanguage: String? {
        didSet {
            defaults.set(translationTargetLanguage, forKey: Key.translationTargetLanguage.rawValue)
            // Remembered so the toggle has somewhere to go back to. Switching
            // translation off and on again should not silently change which
            // language it was going to.
            if let translationTargetLanguage {
                lastTranslationTarget = translationTargetLanguage
            }
        }
    }
    /// The last target actually used, so toggling back on restores it.
    public var lastTranslationTarget: String {
        didSet { defaults.set(lastTranslationTarget, forKey: Key.lastTranslationTarget.rawValue) }
    }
    public var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled.rawValue) } }
    /// Age ceiling for stored dictations, in days. Zero means keep them until
    /// the count cap pushes them out.
    public var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays.rawValue) }
    }

    /// `historyRetentionDays` as the interval `TranscriptHistory` wants, with
    /// zero mapped to "no age limit" so the two representations cannot drift.
    public var historyMaxAge: TimeInterval? {
        historyRetentionDays > 0 ? TimeInterval(historyRetentionDays) * 24 * 60 * 60 : nil
    }
    public var onboardingVersion: Int {
        didSet { defaults.set(onboardingVersion, forKey: Key.onboardingVersion.rawValue) }
    }
    /// Distinguishes an interrupted first run from an older installation that
    /// predates the setup assistant. Closing the assistant must not silently
    /// turn into "completed" on the next launch just because permissions were
    /// granted before it was closed.
    /// Which setup step is open, so the assistant can come back to it.
    ///
    /// Granting Accessibility or Input Monitoring makes macOS quit Plainsay —
    /// that is how those grants take effect. Setup therefore gets interrupted
    /// precisely when the user does the thing setup asked them to do, and
    /// restarting it from the first screen makes it look as though the grant
    /// undid their progress. Zero means "start at the beginning".
    public var onboardingStep: Int {
        didSet { defaults.set(onboardingStep, forKey: Key.onboardingStep.rawValue) }
    }
    public var onboardingWasPresented: Bool {
        didSet { defaults.set(onboardingWasPresented, forKey: Key.onboardingWasPresented.rawValue) }
    }
    /// Leave the dictation on the clipboard instead of restoring what was there.
    /// Insurance for apps that silently swallow a synthetic ⌘V.
    public var keepOnClipboard: Bool { didSet { defaults.set(keepOnClipboard, forKey: Key.keepOnClipboard.rawValue) } }
    /// Shows a running, unedited preview of what's being heard while
    /// recording, in the HUD. Never changes what gets inserted — the final
    /// pipeline still transcribes and cleans the complete recording from
    /// scratch once you stop. On-device only: a partial call every couple of
    /// seconds would be far too slow and costly against a paid API.
    public var livePreviewEnabled: Bool { didSet { defaults.set(livePreviewEnabled, forKey: Key.livePreviewEnabled.rawValue) } }

    /// Filters out any voice that doesn't match `voiceEmbedding` before
    /// transcription, so a second person in the room never reaches the
    /// speech model. Only takes effect once a sample has been enrolled.
    public var voiceFilterEnabled: Bool { didSet { defaults.set(voiceFilterEnabled, forKey: Key.voiceFilterEnabled.rawValue) } }
    /// 256-dimensional voice embedding from FluidAudio's diarizer, captured
    /// once during enrollment. Nil means no one has enrolled a voice yet.
    public var voiceEmbedding: [Float]? { didSet { persist(voiceEmbedding, .voiceEmbedding) } }
    /// Languages the user actually speaks, most-used first. Empty means fully
    /// automatic multilingual decoding across everything Whisper knows.
    public var spokenLanguages: [String] { didSet { persist(spokenLanguages, .language) } }

    /// Overrides Plainsay's own interface language (menus, Settings, the
    /// Setup Assistant, the HUD) — separate from `spokenLanguages`, which is
    /// about what the speech models listen for. Nil follows the system
    /// language, same as any app without this setting.
    public var interfaceLanguage: String? {
        didSet {
            defaults.set(interfaceLanguage, forKey: Key.interfaceLanguage.rawValue)
            Localization.setOverride(interfaceLanguage)
        }
    }

    /// The single language to force on engines that cannot retry a
    /// mismatched auto-detection (remote/cloud ASR). Nil leaves those
    /// engines on full auto-detect, same as an empty `spokenLanguages`.
    public var primaryLanguage: String? { spokenLanguages.first }

    public var geminiAPIKey: String {
        get { Keychain.get(account: Keychain.geminiKeyAccount) ?? "" }
        set { Keychain.set(newValue, account: Keychain.geminiKeyAccount) }
    }

    public var hasGeminiKey: Bool { !geminiAPIKey.isEmpty }

    // Keys are stored per provider, so switching back and forth does not make
    // you paste them in again.
    public func apiKey(for provider: CleanupProvider) -> String {
        Keychain.get(account: provider.keychainAccount) ?? ""
    }

    public func setAPIKey(_ key: String, for provider: CleanupProvider) {
        Keychain.set(key, account: provider.keychainAccount)
    }

    public func apiKey(for provider: ASRProvider) -> String {
        Keychain.get(account: provider.keychainAccount) ?? ""
    }

    public func setAPIKey(_ key: String, for provider: ASRProvider) {
        Keychain.set(key, account: provider.keychainAccount)
    }

    /// Resolved values, falling back to the provider's defaults.
    public var resolvedCleanupModel: String {
        cleanupModel.isEmpty ? cleanupProvider.defaultModel : cleanupModel
    }

    /// Only ever the stored custom URL when `.custom` is actually selected —
    /// the Base URL field only shows in Settings for `.custom`, but this used
    /// to fall back to whatever was last typed there for *every* provider
    /// once it was non-empty. Configure a custom endpoint, switch the picker
    /// to a preset provider, and that preset's key plus every recorded
    /// transcript kept going to the old custom host, with nothing in the UI
    /// showing it.
    public var resolvedCleanupBaseURL: String {
        cleanupProvider == .custom ? cleanupBaseURL : cleanupProvider.defaultBaseURL
    }

    public var resolvedASRModel: String {
        asrModel.isEmpty ? asrProvider.defaultModel : asrModel
    }

    /// See `resolvedCleanupBaseURL` — same fix, same reason.
    public var resolvedASRBaseURL: String {
        asrProvider == .custom ? asrBaseURL : asrProvider.defaultBaseURL
    }

    /// Whether cleanup can actually run as configured.
    ///
    /// `.plainsay` is excluded from the key/model checks below: its
    /// credential comes from a Cloud subscription, not a stored key, and
    /// `CloudSettingsView` already shows its own accurate sign-in/subscribe
    /// status — this just needs to not falsely warn "missing API key".
    public var cleanupIsConfigured: Bool {
        guard cleanupEnabled else { return false }
        if cleanupProvider == .plainsay { return true }
        return !apiKey(for: cleanupProvider).isEmpty
            && !resolvedCleanupModel.isEmpty
            && !resolvedCleanupBaseURL.isEmpty
    }

    public var needsOnboarding: Bool {
        onboardingVersion < Self.currentOnboardingVersion
    }

    /// Commits the Setup Assistant's speech draft after every required field
    /// has been configured. Plainsay Cloud is sold as transcription with
    /// Polishing included, so confirming that plan must select the hosted
    /// cleaner as well as the hosted speech engine. The other speech sources
    /// deliberately preserve the user's independent Polishing choice.
    ///
    /// - Returns: Whether the running speech/Cloud configuration needs to be
    ///   refreshed after the commit.
    @discardableResult
    public func applySetupSpeechSelection(
        source: TranscriptionSource,
        model: OnDeviceModel
    ) -> Bool {
        let bundledPolishingChanged = source.bundlesPolishing
            && (!cleanupEnabled || cleanupProvider != .plainsay)
        let changed = source != transcriptionSource
            || model != self.model
            || bundledPolishingChanged

        transcriptionSource = source
        self.model = model

        if source.bundlesPolishing {
            cleanupEnabled = true
            cleanupProvider = .plainsay
        }

        return changed
    }

    /// Version 0 predates the setup assistant. Existing preferences or a fully
    /// authorized installation identify an existing user who should not be put
    /// through first-run setup merely because the app was updated.
    @discardableResult
    public func migrateLegacyOnboardingIfNeeded(allPermissionsGranted: Bool) -> Bool {
        guard onboardingVersion == 0,
              !onboardingWasPresented,
              allPermissionsGranted || hadLegacyConfiguration
        else { return false }
        onboardingVersion = Self.currentOnboardingVersion
        return true
    }

    private enum Key: String {
        case binding, hotkeyMode, model, dictionary, cleanupEnabled, playFeedbackSounds, language, keepOnClipboard
        case livePreviewEnabled
        case historyEnabled, historyRetentionDays
        case emailModeEnabled, translationTargetLanguage, lastTranslationTarget
        case voiceFilterEnabled, voiceEmbedding
        case onboardingVersion, onboardingWasPresented, onboardingStep
        case cleanupProvider, cleanupModel, cleanupBaseURL
        case dismissedTermProposals
        case transcriptionSource, asrProvider, asrModel, asrBaseURL
        case interfaceLanguage
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hadLegacyConfiguration = Self.legacyConfigurationKeys.contains {
            defaults.object(forKey: $0.rawValue) != nil
        }

        func decode<T: Decodable>(_ key: Key, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: key.rawValue),
                  let value = try? JSONDecoder().decode(T.self, from: data)
            else { return fallback }
            return value
        }

        binding = decode(.binding, HotkeyBinding.rightCommandKey)
        hotkeyMode = decode(.hotkeyMode, HotkeyMode.hybrid)
        model = decode(.model, OnDeviceModel.largeV3Turbo)
        // "Plainsay" is a made-up word, and Whisper mishears made-up words —
        // seeded by default so a fresh install spells its own name correctly
        // without the user having to notice and add it themselves. Only
        // applies when no dictionary was ever saved; an existing user's
        // dictionary, even an empty one, is never overwritten.
        dictionary = decode(.dictionary, TermDictionary(terms: ["Plainsay"]))
        dismissedTermProposals = defaults.stringArray(forKey: Key.dismissedTermProposals.rawValue) ?? []
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled.rawValue) as? Bool ?? true
        playFeedbackSounds = defaults.object(forKey: Key.playFeedbackSounds.rawValue) as? Bool ?? true
        historyEnabled = defaults.object(forKey: Key.historyEnabled.rawValue) as? Bool ?? true
        emailModeEnabled = defaults.object(forKey: Key.emailModeEnabled.rawValue) as? Bool ?? false
        translationTargetLanguage = defaults.string(forKey: Key.translationTargetLanguage.rawValue)
        // English by default: the common target, and often not something
        // people list among the languages they speak.
        lastTranslationTarget = defaults.string(forKey: Key.lastTranslationTarget.rawValue) ?? "en"
        // 30 days by default rather than "for ever": a transcript older than
        // that has outlived the recovery it exists for. Existing installs get
        // the same window — `integer(forKey:)` returns 0 for an absent key,
        // which would silently mean "keep everything" for exactly the users
        // who already have the most stored.
        historyRetentionDays = defaults.object(forKey: Key.historyRetentionDays.rawValue) as? Int ?? 30
        onboardingVersion = defaults.integer(forKey: Key.onboardingVersion.rawValue)
        onboardingWasPresented = defaults.object(forKey: Key.onboardingWasPresented.rawValue) as? Bool ?? false
        onboardingStep = defaults.integer(forKey: Key.onboardingStep.rawValue)
        keepOnClipboard = defaults.object(forKey: Key.keepOnClipboard.rawValue) as? Bool ?? false
        livePreviewEnabled = defaults.object(forKey: Key.livePreviewEnabled.rawValue) as? Bool ?? false
        voiceFilterEnabled = defaults.object(forKey: Key.voiceFilterEnabled.rawValue) as? Bool ?? false
        voiceEmbedding = decode(.voiceEmbedding, [Float]?.none)
        cleanupProvider = decode(.cleanupProvider, CleanupProvider.gemini)
        cleanupModel = defaults.string(forKey: Key.cleanupModel.rawValue) ?? ""
        cleanupBaseURL = defaults.string(forKey: Key.cleanupBaseURL.rawValue) ?? ""
        transcriptionSource = decode(.transcriptionSource, TranscriptionSource.onDevice)
        asrProvider = decode(.asrProvider, ASRProvider.groq)
        asrModel = defaults.string(forKey: Key.asrModel.rawValue) ?? ""
        asrBaseURL = defaults.string(forKey: Key.asrBaseURL.rawValue) ?? ""
        spokenLanguages = decode(.language, [])
        interfaceLanguage = defaults.string(forKey: Key.interfaceLanguage.rawValue)
        Localization.setOverride(interfaceLanguage)
    }

    private func persist<T: Encodable>(_ value: T, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }

    /// Onboarding keys are intentionally excluded: they describe setup state,
    /// not evidence that an older Plainsay release was configured and used.
    private static let legacyConfigurationKeys: [Key] = [
        .binding,
        .hotkeyMode,
        .model,
        .dictionary,
        .cleanupEnabled,
        .playFeedbackSounds,
        .language,
        .keepOnClipboard,
        .livePreviewEnabled,
        .voiceFilterEnabled,
        .cleanupProvider,
        .cleanupModel,
        .cleanupBaseURL,
        .transcriptionSource,
        .asrProvider,
        .asrModel,
        .asrBaseURL,
    ]
}
