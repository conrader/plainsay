import PlainsayCore

/// remember-correction strings (SPEC.fixed.md §2.7). Read through
/// `Localization` so the interface-language override applies; every key has
/// English and Polish in `Localizable.xcstrings`, and the fallbacks here are
/// the catalog English.
enum RuleText {
    private static func s(_ key: String, _ fallback: String) -> String {
        Localization.appString(key, fallback: fallback)
    }

    // MARK: Correction window card

    static var offerTitle: String { s("rules.offer.title", "Remember this correction?") }
    static func offerBody(from: String, to: String) -> String {
        Localization.appFormat("rules.offer.body",
            fallback: "Next time, write \"%2$@\" whenever Plainsay would write \"%1$@\".", from, to)
    }
    static var remember: String { s("rules.offer.remember", "Remember…") }
    static var notNow: String { s("rules.offer.notNow", "Not now") }
    static var fromLabel: String { s("rules.confirm.from", "When Plainsay writes") }
    static var toLabel: String { s("rules.confirm.to", "Write instead") }
    static var scope: String {
        s("rules.confirm.scope", "Only this exact phrase is replaced, everywhere you dictate, on this Mac.")
    }
    static var inflection: String {
        s("rules.confirm.inflection", "Other forms of the word (e.g. other endings) need their own rule.")
    }
    static func addToVocabulary(_ term: String) -> String {
        Localization.appFormat("rules.confirm.vocabulary",
            fallback: "Also add \"%@\" to Vocabulary (sent as a hint to your speech and Polishing services)", term)
    }
    static var vocabularyFuzzy: String {
        s("rules.confirm.vocabularyFuzzy", "Plainsay will then also correct similar spellings.")
    }
    static var save: String { s("rules.confirm.save", "Save rule") }
    static var saveAnyway: String { s("rules.confirm.saveAnyway", "Save anyway") }
    static var cancel: String { s("rules.confirm.cancel", "Cancel") }
    static var saved: String {
        s("rules.saved", "Remembered. Manage rules in Settings → Speech → Replacement rules.")
    }
    static var forget: String { s("rules.forget", "Forget this rule") }
    static var forgotten: String { s("rules.forgotten", "Rule forgotten.") }
    static func inverse(from: String, to: String) -> String {
        Localization.appFormat("rules.inverse",
            fallback: "This reverses your rule \"%1$@ → %2$@\". Turn that rule off?", from, to)
    }
    static var turnOff: String { s("rules.inverse.off", "Turn off") }
    static var keep: String { s("rules.inverse.keep", "Keep") }
    static var turnedOff: String {
        s("rules.inverse.done", "Rule turned off. Turn it back on in Settings → Speech → Replacement rules.")
    }
    static func duplicate(_ from: String) -> String {
        Localization.appFormat("rules.duplicate", fallback: "A rule for \"%@\" already exists. Replace it?", from)
    }
    static var replace: String { s("rules.duplicate.replace", "Replace") }

    static func warning(_ warning: ReplacementWarning) -> String {
        switch warning {
        case .shortWord:
            s("rules.warn.short", "Short phrases can change other words. Check it only matches what you mean.")
        }
    }

    /// The confirmation text for a pair the offer would not have suggested.
    static func caution(_ caution: ReplacementSuppression, from: String) -> String {
        switch caution {
        case .commonWord:
            Localization.appFormat("rules.warn.common",
                fallback: "\"%@\" is a common word. This rule will change it everywhere.", from)
        case .structuredDetail, .date, .spelledNumber:
            s("rules.warn.factual",
              "This looks like a one-time fact (a date, day, number or address), not a spelling. Save anyway?")
        }
    }

    static func rejection(_ reason: ReplacementRejection, from: String) -> String {
        switch reason {
        case .empty: s("rules.reject.empty", "Fill in both phrases.")
        case .identical: s("rules.reject.same", "The new spelling is the same.")
        case .containsFrom:
            s("rules.reject.contains", "The new spelling contains the old phrase, so the rule would repeat itself.")
        case .fromTooLong, .toTooLong:
            s("rules.reject.tooLong", "Rules are for short phrases: up to 4 words, replaced by up to 8.")
        case .tooShort: s("rules.reject.tooShort", "A single word needs at least 3 letters.")
        case .vocabularyTerm:
            Localization.appFormat("rules.reject.vocabulary",
                fallback: "\"%@\" is in your Vocabulary. Remove it there first.", from)
        case .limitReached: s("rules.reject.limit", "You have 200 rules, the maximum.")
        }
    }

    // MARK: Settings

    static var settingsTitle: String { s("settings.rules.title", "Replacement rules") }
    static var settingsToggle: String { s("settings.rules.toggle", "Apply replacement rules") }
    static var settingsExplanation: String {
        s("settings.rules.explanation",
          "Exact phrases replaced on this Mac after Polishing, just before Plainsay types. Rules never leave this Mac.")
    }
    static var settingsTranslation: String {
        s("settings.rules.translation",
          "With translation or email layout on, rules apply to the translated or laid-out text.")
    }
    static var settingsEmpty: String {
        s("settings.rules.empty",
          "No rules yet. After you fix a dictation with \"Change … to …\", Plainsay can offer to remember it.")
    }
    static var sourceCorrection: String { s("settings.rules.source.correction", "From a correction") }
    static var sourceManual: String { s("settings.rules.source.manual", "Added by you") }
    static func delete(from: String, to: String) -> String {
        Localization.appFormat("settings.rules.delete", fallback: "Delete rule %1$@ → %2$@", from, to)
    }
    static func enable(from: String, to: String) -> String {
        Localization.appFormat("settings.rules.enable", fallback: "Use rule %1$@ → %2$@", from, to)
    }
}
