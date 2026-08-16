import Foundation

/// A language Whisper/Parakeet can transcribe, for the "languages I speak"
/// picker in Settings and the Setup Assistant.
///
/// Mirrors Whisper's fixed 99-language training set (WhisperKit's
/// `Constants.languages`, deduplicated to one canonical name per code) rather
/// than importing WhisperKit into the app target just for this list.
public struct SupportedLanguage: Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    /// First two letters (ignoring script/region suffixes) for comparing
    /// codes like `"en-US"` or `"pt_BR"` against Whisper's bare codes.
    public static func primaryCode(_ code: String) -> String {
        code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code.lowercased()
    }

    public static let all: [SupportedLanguage] = [
        SupportedLanguage(code: "en", name: "English"),
        SupportedLanguage(code: "zh", name: "Chinese"),
        SupportedLanguage(code: "de", name: "German"),
        SupportedLanguage(code: "es", name: "Spanish"),
        SupportedLanguage(code: "ru", name: "Russian"),
        SupportedLanguage(code: "ko", name: "Korean"),
        SupportedLanguage(code: "fr", name: "French"),
        SupportedLanguage(code: "ja", name: "Japanese"),
        SupportedLanguage(code: "pt", name: "Portuguese"),
        SupportedLanguage(code: "tr", name: "Turkish"),
        SupportedLanguage(code: "pl", name: "Polish"),
        SupportedLanguage(code: "ca", name: "Catalan"),
        SupportedLanguage(code: "nl", name: "Dutch"),
        SupportedLanguage(code: "ar", name: "Arabic"),
        SupportedLanguage(code: "sv", name: "Swedish"),
        SupportedLanguage(code: "it", name: "Italian"),
        SupportedLanguage(code: "id", name: "Indonesian"),
        SupportedLanguage(code: "hi", name: "Hindi"),
        SupportedLanguage(code: "fi", name: "Finnish"),
        SupportedLanguage(code: "vi", name: "Vietnamese"),
        SupportedLanguage(code: "he", name: "Hebrew"),
        SupportedLanguage(code: "uk", name: "Ukrainian"),
        SupportedLanguage(code: "el", name: "Greek"),
        SupportedLanguage(code: "ms", name: "Malay"),
        SupportedLanguage(code: "cs", name: "Czech"),
        SupportedLanguage(code: "ro", name: "Romanian"),
        SupportedLanguage(code: "da", name: "Danish"),
        SupportedLanguage(code: "hu", name: "Hungarian"),
        SupportedLanguage(code: "ta", name: "Tamil"),
        SupportedLanguage(code: "no", name: "Norwegian"),
        SupportedLanguage(code: "th", name: "Thai"),
        SupportedLanguage(code: "ur", name: "Urdu"),
        SupportedLanguage(code: "hr", name: "Croatian"),
        SupportedLanguage(code: "bg", name: "Bulgarian"),
        SupportedLanguage(code: "lt", name: "Lithuanian"),
        SupportedLanguage(code: "la", name: "Latin"),
        SupportedLanguage(code: "mi", name: "Maori"),
        SupportedLanguage(code: "ml", name: "Malayalam"),
        SupportedLanguage(code: "cy", name: "Welsh"),
        SupportedLanguage(code: "sk", name: "Slovak"),
        SupportedLanguage(code: "te", name: "Telugu"),
        SupportedLanguage(code: "fa", name: "Persian"),
        SupportedLanguage(code: "lv", name: "Latvian"),
        SupportedLanguage(code: "bn", name: "Bengali"),
        SupportedLanguage(code: "sr", name: "Serbian"),
        SupportedLanguage(code: "az", name: "Azerbaijani"),
        SupportedLanguage(code: "sl", name: "Slovenian"),
        SupportedLanguage(code: "kn", name: "Kannada"),
        SupportedLanguage(code: "et", name: "Estonian"),
        SupportedLanguage(code: "mk", name: "Macedonian"),
        SupportedLanguage(code: "br", name: "Breton"),
        SupportedLanguage(code: "eu", name: "Basque"),
        SupportedLanguage(code: "is", name: "Icelandic"),
        SupportedLanguage(code: "hy", name: "Armenian"),
        SupportedLanguage(code: "ne", name: "Nepali"),
        SupportedLanguage(code: "mn", name: "Mongolian"),
        SupportedLanguage(code: "bs", name: "Bosnian"),
        SupportedLanguage(code: "kk", name: "Kazakh"),
        SupportedLanguage(code: "sq", name: "Albanian"),
        SupportedLanguage(code: "sw", name: "Swahili"),
        SupportedLanguage(code: "gl", name: "Galician"),
        SupportedLanguage(code: "mr", name: "Marathi"),
        SupportedLanguage(code: "pa", name: "Punjabi"),
        SupportedLanguage(code: "si", name: "Sinhala"),
        SupportedLanguage(code: "km", name: "Khmer"),
        SupportedLanguage(code: "sn", name: "Shona"),
        SupportedLanguage(code: "yo", name: "Yoruba"),
        SupportedLanguage(code: "so", name: "Somali"),
        SupportedLanguage(code: "af", name: "Afrikaans"),
        SupportedLanguage(code: "oc", name: "Occitan"),
        SupportedLanguage(code: "ka", name: "Georgian"),
        SupportedLanguage(code: "be", name: "Belarusian"),
        SupportedLanguage(code: "tg", name: "Tajik"),
        SupportedLanguage(code: "sd", name: "Sindhi"),
        SupportedLanguage(code: "gu", name: "Gujarati"),
        SupportedLanguage(code: "am", name: "Amharic"),
        SupportedLanguage(code: "yi", name: "Yiddish"),
        SupportedLanguage(code: "lo", name: "Lao"),
        SupportedLanguage(code: "uz", name: "Uzbek"),
        SupportedLanguage(code: "fo", name: "Faroese"),
        SupportedLanguage(code: "ht", name: "Haitian Creole"),
        SupportedLanguage(code: "ps", name: "Pashto"),
        SupportedLanguage(code: "tk", name: "Turkmen"),
        SupportedLanguage(code: "nn", name: "Nynorsk"),
        SupportedLanguage(code: "mt", name: "Maltese"),
        SupportedLanguage(code: "sa", name: "Sanskrit"),
        SupportedLanguage(code: "lb", name: "Luxembourgish"),
        SupportedLanguage(code: "my", name: "Myanmar"),
        SupportedLanguage(code: "bo", name: "Tibetan"),
        SupportedLanguage(code: "tl", name: "Tagalog"),
        SupportedLanguage(code: "mg", name: "Malagasy"),
        SupportedLanguage(code: "as", name: "Assamese"),
        SupportedLanguage(code: "tt", name: "Tatar"),
        SupportedLanguage(code: "haw", name: "Hawaiian"),
        SupportedLanguage(code: "ln", name: "Lingala"),
        SupportedLanguage(code: "ha", name: "Hausa"),
        SupportedLanguage(code: "ba", name: "Bashkir"),
        SupportedLanguage(code: "jw", name: "Javanese"),
        SupportedLanguage(code: "su", name: "Sundanese"),
        SupportedLanguage(code: "yue", name: "Cantonese"),
    ].sorted { $0.name < $1.name }

    /// `name` shown in whatever language Plainsay's own interface is
    /// currently in — e.g. "niemiecki" rather than "German" once the
    /// interface language is Polish — rather than a name hand-translated
    /// into however many languages this list has entries in. macOS already
    /// ships every one of these translated; reuse that instead of a second,
    /// hand-maintained copy.
    public var localizedName: String {
        Locale(identifier: Localization.resolvedCode).localizedString(forLanguageCode: code) ?? name
    }

    public static func named(_ code: String) -> String {
        let primary = primaryCode(code)
        return all.first { $0.code == primary }?.localizedName ?? code
    }
}
