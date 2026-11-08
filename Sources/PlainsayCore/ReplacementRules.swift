import Foundation

/// One exact-phrase replacement the user chose to keep, such as
/// `Kowalsky → Kowalski`. Rules are local data: they are never put in an ASR
/// prompt or a Polishing request.
public struct ReplacementRule: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable { case correction, manual }

    public var id: UUID
    public var from: String
    public var to: String
    public var isEnabled: Bool
    public var source: Source
    public var createdAt: Date

    public init(id: UUID = UUID(), from: String, to: String, isEnabled: Bool = true,
                source: Source = .correction, createdAt: Date = Date()) {
        self.id = id
        self.from = from
        self.to = to
        self.isEnabled = isEnabled
        self.source = source
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, from, to, isEnabled, source, createdAt }

    /// Every field but `from`/`to` is optional, and an unknown `source` falls
    /// back to `.manual`, so a rule written by a newer or older build still
    /// loads. A rule without a usable `from`/`to` throws, and the set skips it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let from = try c.decode(String.self, forKey: .from)
        let to = try c.decode(String.self, forKey: .to)
        guard !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Empty rule phrase"))
        }
        self.from = from
        self.to = to
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .manual
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}

/// The user's replacement rules, applied in one pass after Polishing.
public struct ReplacementRuleSet: Codable, Sendable, Equatable {
    public static let limit = 200

    public var isEnabled: Bool
    public var rules: [ReplacementRule]

    public init(isEnabled: Bool = true, rules: [ReplacementRule] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, rules }

    /// Lossy on purpose. `PlainsaySettings.decode` falls back to an empty value
    /// on any error, and the next save would then erase every rule the user
    /// curated. Here one malformed rule is dropped and the rest survive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        let lossy = (try? c.decodeIfPresent([LossyRule].self, forKey: .rules)) ?? []
        rules = lossy.compactMap(\.rule)
    }

    private struct LossyRule: Decodable {
        let rule: ReplacementRule?
        init(from decoder: Decoder) throws { rule = try? ReplacementRule(from: decoder) }
    }

    // MARK: Lookup and editing

    /// Case-insensitive, whitespace-collapsed, NFC key used for "same phrase".
    static func key(_ phrase: String) -> String {
        phrase.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    public func rule(forFrom from: String) -> ReplacementRule? {
        let k = Self.key(from)
        return rules.first { Self.key($0.from) == k }
    }

    /// An enabled rule that the correction `from → to` exactly reverses, e.g.
    /// the user corrects `JSON` back to `jason` while `jason → JSON` exists.
    public func inverse(of from: String, _ to: String) -> ReplacementRule? {
        let f = Self.key(from), t = Self.key(to)
        return rules.first { $0.isEnabled && Self.key($0.from) == t && Self.key($0.to) == f }
    }

    /// Replaces the rule with the same `from` phrase, or appends a new one.
    /// Returns false, changing nothing, when appending would pass `limit`.
    @discardableResult
    public mutating func upsert(_ rule: ReplacementRule) -> Bool {
        let k = Self.key(rule.from)
        if let index = rules.firstIndex(where: { Self.key($0.from) == k }) {
            rules[index] = rule
            return true
        }
        guard rules.count < Self.limit else { return false }
        rules.append(rule)
        return true
    }

    public mutating func remove(id: UUID) { rules.removeAll { $0.id == id } }

    public mutating func setEnabled(_ enabled: Bool, id: UUID) {
        if let index = rules.firstIndex(where: { $0.id == id }) { rules[index].isEnabled = enabled }
    }

    // MARK: Applying

    /// Horizontal whitespace only: rules run after e-mail layout, and `\s+`
    /// would join a phrase across a line or paragraph break.
    static let phraseGap = #"[\p{Zs}\t]+"#
    /// Word boundaries as in `DictationCorrectionCommand.localReplacement`,
    /// plus: no match glued to `@` (handles) or to `.`+letter/digit on either
    /// side (bare domains and file names such as `jason.dev`, `jason.txt`),
    /// and no match that is one component of a time, decimal or date.
    static let before = #"(?<![\p{L}\p{N}_@])(?<![\p{L}\p{N}][.])(?<![\p{N}][,:/-])"#
    static let after = #"(?![\p{L}\p{N}_])(?![.][\p{L}\p{N}])(?![,:/-][\p{N}])"#

    /// One left-to-right pass over `text` with every enabled rule, longest
    /// phrase first. Output is never rescanned, so `A→B`, `B→C` turns `A`
    /// into `B`. Matches inside a URL or e-mail address are skipped. Returns
    /// the original string untouched when nothing fired.
    public func apply(to text: String) -> (text: String, count: Int) {
        guard isEnabled else { return (text, 0) }
        var seen = Set<String>()
        let active = rules
            .filter { $0.isEnabled }
            .map { (from: $0.from.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines),
                    to: $0.to.precomposedStringWithCanonicalMapping) }
            .filter { !$0.from.isEmpty && seen.insert(Self.key($0.from)).inserted }
            .sorted { lhs, rhs in
                let l = lhs.from.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let r = rhs.from.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                return l.count != r.count ? l.count > r.count : l < r
            }
        guard !active.isEmpty else { return (text, 0) }

        let alternatives = active.map { rule in
            "(" + rule.from.split(whereSeparator: { $0.isWhitespace })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: Self.phraseGap) + ")"
        }
        let pattern = Self.before + "(?:" + alternatives.joined(separator: "|") + ")" + Self.after
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (text, 0)
        }

        let source = text.precomposedStringWithCanonicalMapping
        let ns = source as NSString
        let protected = StructuredDetails.spans(in: source).filter { $0.kind != .number }.map(\.range)
        var replacements: [(range: NSRange, with: String)] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            if protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            guard let index = (1...active.count).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
            let matched = ns.substring(with: match.range)
            let replacement = Self.cased(active[index - 1].to, like: matched)
            // Already correct (`jira → Jira` on "Jira"): not a firing.
            if replacement == matched { continue }
            replacements.append((match.range, replacement))
        }
        guard !replacements.isEmpty else { return (text, 0) }
        let output = NSMutableString(string: source)
        for replacement in replacements.reversed() {
            output.replaceCharacters(in: replacement.range, with: replacement.with)
        }
        return (output as String, replacements.count)
    }

    /// `to` verbatim, except that an all-lowercase `to` gets its first letter
    /// raised when the matched text started with a capital (sentence starts).
    static func cased(_ to: String, like matched: String) -> String {
        guard to == to.lowercased(), to != to.uppercased(),
              let first = matched.first, first.isUppercase else { return to }
        return to.prefix(1).uppercased() + to.dropFirst()
    }
}
