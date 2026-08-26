import Foundation

/// Detects a transcript that came out in a language the speaker does not speak.
///
/// Motivated by a real report: "unieważnij", said in Polish by someone whose
/// languages are English and Polish, came back as Czech.
///
/// The language *hint* does not prevent this. FluidAudio's filter partitions
/// decoder tokens by Unicode script only — its own comment says "a per-language
/// token allowlist (Polish vs Czech etc.) could plug in here later" — and
/// Polish and Czech are both Latin, so the hint rules out Cyrillic and nothing
/// else. Parakeet also reports no detected language, so the engine cannot be
/// asked what it thought it heard.
///
/// What it *can* be asked is what it wrote. Several Latin-script languages use
/// letters no other language in the set uses, and those letters are decisive:
/// a "ř" is Czech, never Polish, no matter which language the model believed it
/// was decoding.
public enum LanguageEvidence {
    /// Letters that occur in exactly one language among the confusable
    /// Latin-script sets, lowercased.
    ///
    /// Deliberately narrow. Only characters that are *exclusive* are listed —
    /// "š" and "č" are shared by Czech, Slovak, Croatian and Slovenian, so they
    /// prove nothing and are absent. A letter here is evidence on its own.
    static let exclusiveLetters: [Character: String] = [
        // Polish: the crossed l and the nasal vowels are unique to it.
        "ł": "pl", "ą": "pl", "ę": "pl", "ń": "pl", "ś": "pl", "ź": "pl", "ż": "pl",
        // Czech: ř is Czech alone; ě and ů are Czech alone in this set.
        "ř": "cs", "ě": "cs", "ů": "cs",
        // Hungarian: the double acute vowels.
        "ő": "hu", "ű": "hu",
        // Romanian: comma-below letters (distinct from Turkish cedilla).
        "ș": "ro", "ț": "ro",
        // Turkish: the dotless i and its capital counterpart.
        "ı": "tr",
        // Danish/Norwegian.
        "ø": "da", "å": "da",
        // German/Swedish/Finnish share ä and ö, so neither appears here.
        "ß": "de",
    ]

    /// Languages `text` shows exclusive evidence of, as primary codes.
    public static func languages(in text: String) -> Set<String> {
        var found: Set<String> = []
        for character in text.lowercased() {
            if let code = exclusiveLetters[character] { found.insert(code) }
        }
        return found
    }

    /// Whether `text` is evidently in a language the speaker did not list.
    ///
    /// False whenever there is any doubt: an empty language list means full
    /// auto-detect and nothing is out of bounds, and text carrying no exclusive
    /// letters is not evidence of anything. The cost of a false positive —
    /// discarding or re-running a transcript that was fine — is paid by the
    /// speaker, so this only fires on a letter that cannot be explained.
    public static func isOutsideSpokenLanguages(_ text: String, spokenLanguages: [String]) -> Bool {
        guard !spokenLanguages.isEmpty else { return false }
        let allowed = Set(spokenLanguages.map(SupportedLanguage.primaryCode))
        let evidence = languages(in: text)
        guard !evidence.isEmpty else { return false }
        return !evidence.subtracting(allowed).isEmpty
    }
}
