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
    public var onboardingVersion: Int {
        didSet { defaults.set(onboardingVersion, forKey: Key.onboardingVersion.rawValue) }
    }
    /// Distinguishes an interrupted first run from an older installation that
    /// predates the setup assistant. Closing the assistant must not silently
    /// turn into "completed" on the next launch just because permissions were
    /// granted before it was closed.
    public var onboardingWasPresented: Bool {
        didSet { defaults.set(onboardingWasPresented, forKey: Key.onboardingWasPresented.rawValue) }
    }
    /// Leave the dictation on the clipboard instead of restoring what was there.
    /// Insurance for apps that silently swallow a synthetic ⌘V.
    public var keepOnClipboard: Bool { didSet { defaults.set(keepOnClipboard, forKey: Key.keepOnClipboard.rawValue) } }
    /// Languages the user actually speaks, most-used first. Empty means fully
    /// automatic multilingual decoding across everything Whisper knows.
    public var spokenLanguages: [String] { didSet { persist(spokenLanguages, .language) } }

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

    public var resolvedCleanupBaseURL: String {
        cleanupBaseURL.isEmpty ? cleanupProvider.defaultBaseURL : cleanupBaseURL
    }

    public var resolvedASRModel: String {
        asrModel.isEmpty ? asrProvider.defaultModel : asrModel
    }

    public var resolvedASRBaseURL: String {
        asrBaseURL.isEmpty ? asrProvider.defaultBaseURL : asrBaseURL
    }

    /// Whether cleanup can actually run as configured.
    public var cleanupIsConfigured: Bool {
        cleanupEnabled
            && !apiKey(for: cleanupProvider).isEmpty
            && !resolvedCleanupModel.isEmpty
            && !resolvedCleanupBaseURL.isEmpty
    }

    public var needsOnboarding: Bool {
        onboardingVersion < Self.currentOnboardingVersion
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
        case onboardingVersion, onboardingWasPresented
        case cleanupProvider, cleanupModel, cleanupBaseURL
        case transcriptionSource, asrProvider, asrModel, asrBaseURL
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
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled.rawValue) as? Bool ?? true
        playFeedbackSounds = defaults.object(forKey: Key.playFeedbackSounds.rawValue) as? Bool ?? true
        onboardingVersion = defaults.integer(forKey: Key.onboardingVersion.rawValue)
        onboardingWasPresented = defaults.object(forKey: Key.onboardingWasPresented.rawValue) as? Bool ?? false
        keepOnClipboard = defaults.object(forKey: Key.keepOnClipboard.rawValue) as? Bool ?? false
        cleanupProvider = decode(.cleanupProvider, CleanupProvider.gemini)
        cleanupModel = defaults.string(forKey: Key.cleanupModel.rawValue) ?? ""
        cleanupBaseURL = defaults.string(forKey: Key.cleanupBaseURL.rawValue) ?? ""
        transcriptionSource = decode(.transcriptionSource, TranscriptionSource.onDevice)
        asrProvider = decode(.asrProvider, ASRProvider.groq)
        asrModel = defaults.string(forKey: Key.asrModel.rawValue) ?? ""
        asrBaseURL = defaults.string(forKey: Key.asrBaseURL.rawValue) ?? ""
        spokenLanguages = decode(.language, [])
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
        .cleanupProvider,
        .cleanupModel,
        .cleanupBaseURL,
        .transcriptionSource,
        .asrProvider,
        .asrModel,
        .asrBaseURL,
    ]
}
