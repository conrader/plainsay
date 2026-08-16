import Foundation

/// A language Plainsay's own interface ships a translation for — the menu
/// bar, Settings, the Setup Assistant, the HUD. Distinct from
/// `SupportedLanguage`, which lists every language the speech models can
/// transcribe; picking an interface language here has no effect on what
/// Plainsay can understand you say.
public struct AppLanguage: Identifiable, Hashable, Sendable {
    /// A BCP-47 code matching one of the `.lproj` directories the app ships,
    /// or nil for "follow the system language."
    public let code: String?
    public var id: String { code ?? "system" }

    public init(code: String?) { self.code = code }

    public static let system = AppLanguage(code: nil)

    /// Every language `Localizable.xcstrings`/`CoreLocalizable.xcstrings`
    /// ship a translation for. Keep in sync with the languages compiled by
    /// `Scripts/bundle.sh`.
    public static let supportedCodes: [String] = [
        "en", "pl", "de", "fr", "es", "it", "pt", "nl", "ja", "ko", "zh-Hans", "ru", "uk",
    ]

    public static let all: [AppLanguage] = [.system] + supportedCodes.map { AppLanguage(code: $0) }

    /// Shown in the picker, in each language's own name (so someone hunting
    /// for their language can recognize it even while the UI is currently in
    /// a language they don't read).
    public var displayName: String {
        guard let code else {
            return Localization.appString("language.system", fallback: "System Language")
        }
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
