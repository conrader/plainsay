import Foundation
import Observation

/// User preferences. The Gemini key is deliberately absent — it lives in the
/// Keychain, not in UserDefaults.
@MainActor
@Observable
public final class PlainsaySettings {
    public static let shared = PlainsaySettings()

    private let defaults: UserDefaults

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
    /// Leave the dictation on the clipboard instead of restoring what was there.
    /// Insurance for apps that silently swallow a synthetic ⌘V.
    public var keepOnClipboard: Bool { didSet { defaults.set(keepOnClipboard, forKey: Key.keepOnClipboard.rawValue) } }
    /// Speech-model language code, or nil for automatic multilingual decoding.
    public var language: String? { didSet { defaults.set(language, forKey: Key.language.rawValue) } }

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

    private enum Key: String {
        case binding, hotkeyMode, model, dictionary, cleanupEnabled, playFeedbackSounds, language, keepOnClipboard
        case cleanupProvider, cleanupModel, cleanupBaseURL
        case transcriptionSource, asrProvider, asrModel, asrBaseURL
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func decode<T: Decodable>(_ key: Key, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: key.rawValue),
                  let value = try? JSONDecoder().decode(T.self, from: data)
            else { return fallback }
            return value
        }

        binding = decode(.binding, HotkeyBinding.rightCommandKey)
        hotkeyMode = decode(.hotkeyMode, HotkeyMode.hybrid)
        model = decode(.model, OnDeviceModel.largeV3Turbo)
        dictionary = decode(.dictionary, TermDictionary())
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled.rawValue) as? Bool ?? true
        playFeedbackSounds = defaults.object(forKey: Key.playFeedbackSounds.rawValue) as? Bool ?? true
        keepOnClipboard = defaults.object(forKey: Key.keepOnClipboard.rawValue) as? Bool ?? false
        cleanupProvider = decode(.cleanupProvider, CleanupProvider.gemini)
        cleanupModel = defaults.string(forKey: Key.cleanupModel.rawValue) ?? ""
        cleanupBaseURL = defaults.string(forKey: Key.cleanupBaseURL.rawValue) ?? ""
        transcriptionSource = decode(.transcriptionSource, TranscriptionSource.onDevice)
        asrProvider = decode(.asrProvider, ASRProvider.groq)
        asrModel = defaults.string(forKey: Key.asrModel.rawValue) ?? ""
        asrBaseURL = defaults.string(forKey: Key.asrBaseURL.rawValue) ?? ""
        language = defaults.string(forKey: Key.language.rawValue)
    }

    private func persist<T: Encodable>(_ value: T, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }
}
