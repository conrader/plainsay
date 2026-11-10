import Foundation

public enum ReplacementRejection: Sendable, Equatable {
    case empty, identical, containsFrom, fromTooLong, toTooLong, tooShort, vocabularyTerm, limitReached
}

/// Why a correction should not be *offered* as a rule. A manual rule with the
/// same pair is still allowed after a warning; these are not rejections.
public enum ReplacementSuppression: Sendable, Equatable {
    /// A number, amount, time, URL or e-mail address differs.
    case structuredDetail
    /// A weekday, month or relative day (EN/PL) differs.
    case date
    /// A spelled-out number (EN/PL) differs: `fifteen→fifty`.
    case spelledNumber
    /// `from` is only function words (`the→a`): a rule would touch every sentence.
    case commonWord
}

public enum ReplacementWarning: Sendable, Equatable {
    /// A single 3–4 character word: likely to occur in unrelated text.
    case shortWord
}

public enum ReplacementAssessment: Sendable, Equatable {
    case offer
    case offerWithWarning(ReplacementWarning)
    case suppressOffer(ReplacementSuppression)
    case reject(ReplacementRejection)

    public var isOffered: Bool {
        switch self {
        case .offer, .offerWithWarning: true
        case .suppressOffer, .reject: false
        }
    }
}

/// Decides whether a correction pair may become a rule, and whether it should
/// be offered. Deliberately free of NLTagger: names are what users correct
/// (`jason→JSON`, `Kowalsky→Kowalski`), so a name tag must never count as a
/// fact. Only the regex details plus closed date and number lists do.
public enum ReplacementRuleValidator {
    /// - Parameter vocabulary: every Vocabulary term in effect, global plus any
    ///   app-profile terms; compared by folded key, as TermDictionary does.
    public static func assess(from rawFrom: String, to rawTo: String,
                              rules: ReplacementRuleSet = ReplacementRuleSet(),
                              vocabulary: [String] = []) -> ReplacementAssessment {
        let from = normalized(rawFrom), to = normalized(rawTo)
        guard !from.isEmpty, !to.isEmpty,
              !rawFrom.contains(where: isControl), !rawTo.contains(where: isControl) else { return .reject(.empty) }
        guard from != to else { return .reject(.identical) }
        let caseOnly = from.lowercased() == to.lowercased()
        if !caseOnly, contains(to, phrase: from) { return .reject(.containsFrom) }
        let fromWords = words(from), toWords = words(to)
        if fromWords.count > maxFromWords || from.count > maxFromLength { return .reject(.fromTooLong) }
        if toWords.count > maxToWords || to.count > maxToLength { return .reject(.toTooLong) }
        let fromSignificant = from.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        if fromWords.count == 1, fromSignificant < 3 { return .reject(.tooShort) }
        let fromKey = TermDictionary.foldedKey(from)
        if !fromKey.isEmpty, vocabulary.contains(where: {
            let term = normalized($0)
            return TermDictionary.foldedKey(term) == fromKey && term != to
        }) { return .reject(.vocabularyTerm) }
        if rules.rules.count >= ReplacementRuleSet.limit, rules.rule(forFrom: from) == nil {
            return .reject(.limitReached)
        }

        if StructuredDetails.values(in: from) != StructuredDetails.values(in: to) {
            return .suppressOffer(.structuredDetail)
        }
        let fromTokens = tokens(from), toTokens = tokens(to)
        if differ(fromTokens, toTokens, in: ReplacementWordLists.dates) { return .suppressOffer(.date) }
        if differ(fromTokens, toTokens, in: ReplacementWordLists.spelledNumbers) { return .suppressOffer(.spelledNumber) }
        if !fromTokens.isEmpty, fromTokens.allSatisfy(ReplacementWordLists.functionWords.contains) { return .suppressOffer(.commonWord) }
        if fromWords.count == 1, fromSignificant <= 4 { return .offerWithWarning(.shortWord) }
        return .offer
    }

    // MARK: Bounds

    static let maxFromWords = 4, maxFromLength = 60
    static let maxToWords = 8, maxToLength = 80

    /// The structural part of `assess` only: both phrases non-blank, free of
    /// control characters and within the word and character limits. Loading
    /// saved rules enforces this; the offer-level checks stay with `assess`.
    static func withinBounds(from rawFrom: String, to rawTo: String) -> Bool {
        guard rawWithinSize(rawFrom, max: maxFromLength), rawWithinSize(rawTo, max: maxToLength) else { return false }
        let from = normalized(rawFrom), to = normalized(rawTo)
        guard !from.isEmpty, !to.isEmpty,
              !rawFrom.contains(where: isControl), !rawTo.contains(where: isControl) else { return false }
        return words(from).count <= maxFromWords && from.count <= maxFromLength
            && words(to).count <= maxToWords && to.count <= maxToLength
    }

    /// A stored phrase is at most `max` characters before normalization,
    /// padding included: `save` stores normalized text, so anything longer
    /// is not ours. The UTF-8 size is checked first (constant time for a
    /// native string) so a huge value is refused without walking it.
    static func rawWithinSize(_ raw: String, max: Int) -> Bool {
        raw.utf8.count <= max * maxBytesPerCharacter && raw.count <= max
    }

    /// Generous: a flag or ZWJ emoji sequence is one character of many bytes.
    static let maxBytesPerCharacter = 32

    // MARK: Helpers

    static func normalized(_ text: String) -> String {
        words(text.precomposedStringWithCanonicalMapping).joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Lowercased letter/digit runs, for list lookups.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    private static func isControl(_ c: Character) -> Bool {
        c.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// A list token changed: both sides use the list and the tokens differ.
    /// A case-only edit (`may→May`) is not a change.
    private static func differ(_ a: [String], _ b: [String], in list: Set<String>) -> Bool {
        let x = a.filter(list.contains), y = b.filter(list.contains)
        return !x.isEmpty && !y.isEmpty && x != y
    }

    /// `phrase` occurs in `text` as a whole-word phrase, case-insensitively.
    private static func contains(_ text: String, phrase: String) -> Bool {
        let body = words(phrase).map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: ReplacementRuleSet.phraseGap)
        let pattern = #"(?<![\p{L}\p{N}_])"# + body + #"(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
