import Foundation

/// The compiled form of a `ReplacementRuleSet`: rules normalized, deduplicated
/// and ordered once, plus one scanning regular expression.
///
/// Matching semantics are those of the single alternation
/// `before (?:(rule1)|(rule2)|…) after`, case-insensitive, longest phrase
/// first, left to right, never rescanning output. Performance notes, measured
/// on the 200-rule / 24,000-character workload in `ReplacementRulesPerfTests`:
///
/// - The scan pattern has no capture groups. ICU saves every capture slot on
///   each alternative it tries, so 200 groups made the scan about 3× slower.
///   Groups do not change which text matches, only which rule we learn.
/// - Which rule matched is recovered per distinct matched string (memoized).
///   For ASCII text that is an exact dictionary lookup: ICU's case-insensitive
///   comparison of two ASCII strings is ASCII case folding. A non-ASCII rule
///   can still match ASCII text (`ſ`, `K`, ligatures), so those rules always
///   stay candidates; whenever more than one candidate remains, an anchored
///   ICU regex over every rule, in the same order, decides: the same engine
///   and the same order as the original single regex. It is compiled at most
///   once per call, only when needed.
/// - The phrase gap is `\h+` instead of `[\p{Zs}\t]+` (see `phraseGap`).
/// - The output is assembled front to back in one pass instead of splicing
///   each replacement into a mutable copy of the whole text.
struct ReplacementMatcher {
    struct Rule {
        /// NFC, trimmed. Words are separated by `phraseGap` in the pattern.
        let words: [Substring]
        /// NFC target.
        let to: String
        /// Lowercased, single-space-joined words when the phrase is ASCII.
        let asciiKey: String?
    }

    /// In match-priority order: longest phrase first, then alphabetical.
    let rules: [Rule]
    private let scanner: NSRegularExpression?
    private let asciiIndex: [String: Int]
    private let nonASCIIIndices: [Int]

    init(rules ruleList: [ReplacementRule]) {
        var seen = Set<String>()
        var prepared: [(rule: Rule, joined: String, length: Int)] = []
        for rule in ruleList where rule.isEnabled {
            let from = rule.from.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { continue }
            let words = from.split(whereSeparator: { $0.isWhitespace })
            let joined = words.joined(separator: " ")
            // Same as ReplacementRuleSet.key(from): `from` is already NFC.
            guard seen.insert(joined.lowercased()).inserted else { continue }
            let ascii = joined.utf8.allSatisfy { $0 < 0x80 }
            prepared.append((Rule(words: words, to: rule.to.precomposedStringWithCanonicalMapping,
                                  asciiKey: ascii ? Self.asciiLowercased(joined) : nil),
                             joined, joined.count))
        }
        prepared.sort { $0.length != $1.length ? $0.length > $1.length : $0.joined < $1.joined }
        rules = prepared.map(\.rule)

        var asciiIndex: [String: Int] = [:]
        var nonASCII: [Int] = []
        for (index, rule) in rules.enumerated() {
            if let key = rule.asciiKey { asciiIndex[key] = asciiIndex[key] ?? index } else { nonASCII.append(index) }
        }
        self.asciiIndex = asciiIndex
        nonASCIIIndices = nonASCII

        if rules.isEmpty {
            scanner = nil
        } else {
            let alternatives = rules.map { "(?:" + Self.body($0) + ")" }.joined(separator: "|")
            let pattern = ReplacementRuleSet.before + "(?:" + alternatives + ")" + ReplacementRuleSet.after
            scanner = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    var isEmpty: Bool { rules.isEmpty }

    func apply(to text: String) -> (text: String, count: Int) {
        guard let scanner else { return (text, 0) }
        let source = text.precomposedStringWithCanonicalMapping
        let ns = source as NSString
        let matches = scanner.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, 0) }

        let protected = StructuredDetails.spans(in: source).filter { $0.kind != .number }.map(\.range)
        // Keyed by UTF-16 units, not String: String equality is canonical
        // equivalence, ICU matching is not.
        var replacementFor: [[UInt16]: String?] = [:]
        var identifier: NSRegularExpression?
        var replacements: [(range: NSRange, with: String)] = []
        for match in matches {
            let range = match.range
            if protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            let matched = ns.substring(with: range)
            let units = Array(matched.utf16)
            let replacement: String?
            if let memo = replacementFor[units] {
                replacement = memo
            } else {
                replacement = ruleIndex(for: matched, units: units, identifier: &identifier)
                    .map { ReplacementRuleSet.cased(rules[$0].to, like: matched) }
                replacementFor[units] = .some(replacement)
            }
            // Already correct (`jira → Jira` on "Jira"): not a firing.
            guard let replacement, replacement != matched else { continue }
            replacements.append((range, replacement))
        }
        guard !replacements.isEmpty else { return (text, 0) }

        var output = ""
        output.reserveCapacity(source.utf8.count + 64)
        var cursor = 0
        for replacement in replacements {
            output += ns.substring(with: NSRange(location: cursor, length: replacement.range.location - cursor))
            output += replacement.with
            cursor = NSMaxRange(replacement.range)
        }
        output += ns.substring(from: cursor)
        return (output, replacements.count)
    }

    /// The first rule, in priority order, whose phrase matches all of
    /// `matched`. Because the scan's `after` assertion depends only on where
    /// a match ends, that is exactly the alternative the scan chose. The
    /// matched rule is always among the candidates, so one candidate needs no
    /// check; otherwise `identifier` (every rule, same order, compiled at most
    /// once per call) decides.
    private func ruleIndex(for matched: String, units: [UInt16],
                           identifier: inout NSRegularExpression?) -> Int? {
        if units.allSatisfy({ $0 < 0x80 }) {
            let key = matched.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            let hit = asciiIndex[Self.asciiLowercased(key)]
            switch (hit, nonASCIIIndices.isEmpty) {
            case (let index?, true): return index
            case (nil, false) where nonASCIIIndices.count == 1: return nonASCIIIndices[0]
            default: break
            }
        }
        if identifier == nil {
            let alternatives = rules.map { "(" + Self.body($0) + ")" }.joined(separator: "|")
            identifier = try? NSRegularExpression(pattern: #"\A(?:"# + alternatives + #")\z"#, options: [.caseInsensitive])
        }
        guard let identifier,
              let match = identifier.firstMatch(in: matched, range: NSRange(location: 0, length: units.count)),
              let group = (1...rules.count).first(where: { match.range(at: $0).location != NSNotFound })
        else { return nil }
        return group - 1
    }

    private static func body(_ rule: Rule) -> String {
        rule.words.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ReplacementRuleSet.phraseGap)
    }

    private static func asciiLowercased(_ s: String) -> String {
        String(decoding: s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
    }
}
