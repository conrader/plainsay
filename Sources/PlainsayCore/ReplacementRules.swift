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
    /// loads. A rule without a usable `from`/`to`, or with a raw phrase
    /// (padding included) over the validator's length limit, throws before
    /// any trimming or normalization, and the set skips it. A missing or
    /// unreadable id is derived from the phrases, so it is the same on every
    /// reload.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let from = try c.decode(String.self, forKey: .from)
        let to = try c.decode(String.self, forKey: .to)
        guard ReplacementRuleValidator.rawWithinSize(from, max: ReplacementRuleValidator.maxFromLength),
              ReplacementRuleValidator.rawWithinSize(to, max: ReplacementRuleValidator.maxToLength),
              !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Unusable rule phrase"))
        }
        self.from = from
        self.to = to
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id))
            ?? ReplacementRuleSet.derivedID("missing\u{1F}\(from)\u{1F}\(to)")
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
    /// Targets of deleted or retargeted rules that History may still hold
    /// (`ReplacementRuleRetirement.swift`).
    public var retiredTargets: [RetiredRuleTarget]
    /// Set while a forgotten retired target may still be in History.
    public var retiredOverflow: RetiredOverflow?

    public init(isEnabled: Bool = true, rules: [ReplacementRule] = [],
                retiredTargets: [RetiredRuleTarget] = [], retiredOverflow: RetiredOverflow? = nil) {
        self.isEnabled = isEnabled
        self.rules = rules
        self.retiredTargets = retiredTargets
        self.retiredOverflow = retiredOverflow
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, rules, retiredTargets, retiredOverflow }

    /// Lossy on purpose. `PlainsaySettings.decode` falls back to an empty value
    /// on any error, and the next save would then erase every rule the user
    /// curated. Here one malformed rule is dropped and the rest survive.
    /// Only the structural bounds are re-checked (`loadable`); the offer-level
    /// checks `save` runs (identical, contained, vocabulary...) are not.
    /// At most `rawElementLimit` stored elements of each list are decoded.
    /// Retired targets that cannot all be kept, or an unreadable overflow
    /// marker, load as an unsettled `retiredOverflow` (conservative).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        rules = Self.loadable(Self.decodeBounded(LossyReplacementRule.self, c, .rules).items.compactMap(\.rule))
        let stored = Self.decodeBounded(LossyRetiredTarget.self, c, .retiredTargets)
        let retired = Self.loadableRetired(stored.items.compactMap(\.target))
        retiredTargets = retired.kept
        if c.contains(.retiredOverflow) {
            retiredOverflow = (try? c.decode(RetiredOverflow.self, forKey: .retiredOverflow)) ?? RetiredOverflow()
        } else {
            retiredOverflow = nil
        }
        if stored.truncated || retired.dropped { retiredOverflow = RetiredOverflow() }
    }

    /// Up to `rawElementLimit` elements of the list under `key`; elements
    /// past it are never decoded (`truncated`). A missing or non-list value
    /// is empty.
    private static func decodeBounded<T: Decodable>(_ type: T.Type, _ c: KeyedDecodingContainer<CodingKeys>,
                                                    _ key: CodingKeys) -> (items: [T], truncated: Bool) {
        guard var list = try? c.nestedUnkeyedContainer(forKey: key) else { return ([], false) }
        var items: [T] = []
        while !list.isAtEnd, items.count < rawElementLimit, let item = try? list.decode(T.self) {
            items.append(item)
        }
        return (items, !list.isAtEnd)
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

    /// Replaces the rule with the same `from` phrase (retiring its old target
    /// if the target changes), or appends a new one.
    /// Returns false, changing nothing, when appending would pass `limit`.
    @discardableResult
    public mutating func upsert(_ rule: ReplacementRule, now: Date = Date()) -> Bool {
        let k = Self.key(rule.from)
        if let index = rules.firstIndex(where: { Self.key($0.from) == k }) {
            if rules[index].to != rule.to { retire(rules[index].to, now: now) }
            rules[index] = rule
            return true
        }
        guard rules.count < Self.limit else { return false }
        rules.append(rule)
        return true
    }

    /// Removes the rule and retires its target (`hasTarget(matching:)`).
    public mutating func remove(id: UUID, now: Date = Date()) {
        for rule in rules where rule.id == id { retire(rule.to, now: now) }
        rules.removeAll { $0.id == id }
    }

    public mutating func setEnabled(_ enabled: Bool, id: UUID) {
        if let index = rules.firstIndex(where: { $0.id == id }) { rules[index].isEnabled = enabled }
    }

    // MARK: Applying

    /// Horizontal whitespace only: rules run after e-mail layout, and `\s+`
    /// would join a phrase across a line or paragraph break. ICU defines `\h`
    /// as exactly `[\p{Zs}\t]` (general category Zs, or U+0009) but tests it
    /// without building a property set. With 200 rules the spelled-out class
    /// cost ~10 ms of regex compilation per call, the largest single item.
    static let phraseGap = #"\h+"#
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
    /// `ReplacementMatcher` holds the compiled form and the performance notes.
    public func apply(to text: String) -> (text: String, count: Int) {
        guard isEnabled else { return (text, 0) }
        return ReplacementMatcher(rules: rules).apply(to: text)
    }

    /// `to` verbatim, except that an all-lowercase `to` gets its first letter
    /// raised when the matched text started with a capital (sentence starts).
    static func cased(_ to: String, like matched: String) -> String {
        guard to == to.lowercased(), to != to.uppercased(),
              let first = matched.first, first.isUppercase else { return to }
        return to.prefix(1).uppercased() + to.dropFirst()
    }
}
