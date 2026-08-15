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
    public var model: WhisperModel { didSet { persist(model, .model) } }
    public var dictionary: TermDictionary { didSet { persist(dictionary, .dictionary) } }
    public var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled.rawValue) } }
    public var playFeedbackSounds: Bool { didSet { defaults.set(playFeedbackSounds, forKey: Key.playFeedbackSounds.rawValue) } }
    /// Leave the dictation on the clipboard instead of restoring what was there.
    /// Insurance for apps that silently swallow a synthetic ⌘V.
    public var keepOnClipboard: Bool { didSet { defaults.set(keepOnClipboard, forKey: Key.keepOnClipboard.rawValue) } }
    /// Whisper language code, or nil to auto-detect.
    public var language: String? { didSet { defaults.set(language, forKey: Key.language.rawValue) } }

    public var geminiAPIKey: String {
        get { Keychain.get(account: Keychain.geminiKeyAccount) ?? "" }
        set { Keychain.set(newValue, account: Keychain.geminiKeyAccount) }
    }

    public var hasGeminiKey: Bool { !geminiAPIKey.isEmpty }

    private enum Key: String {
        case binding, hotkeyMode, model, dictionary, cleanupEnabled, playFeedbackSounds, language, keepOnClipboard
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
        model = decode(.model, WhisperModel.largeV3Turbo)
        dictionary = decode(.dictionary, TermDictionary())
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled.rawValue) as? Bool ?? true
        playFeedbackSounds = defaults.object(forKey: Key.playFeedbackSounds.rawValue) as? Bool ?? true
        keepOnClipboard = defaults.object(forKey: Key.keepOnClipboard.rawValue) as? Bool ?? false
        language = defaults.string(forKey: Key.language.rawValue)
    }

    private func persist<T: Encodable>(_ value: T, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }
}
