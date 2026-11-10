import Foundation

/// Loading persisted rules. Stored data is not trusted to have gone through
/// `save`, and a malformed store must not cost unbounded work or produce
/// different rules on each launch.
extension ReplacementRuleSet {
    /// At most this many stored elements of `rules` (and of
    /// `retiredTargets`) are decoded; the rest are never looked at.
    static let rawElementLimit = 4 * limit

    /// In stored order: a rule outside the validator's structural bounds
    /// (raw and normalized length, word count, control characters) is
    /// dropped; a second rule for the same `from` key (`key(_:)`: NFC, case,
    /// whitespace) is dropped, the first wins as in `rule(forFrom:)`; a rule
    /// reusing an earlier rule's id gets an id derived from its old id and
    /// phrase, so the Settings list and `remove`/`setEnabled` address exactly
    /// one rule and the repaired id is the same on every reload; rules past
    /// `limit` are dropped.
    static func loadable(_ decoded: [ReplacementRule]) -> [ReplacementRule] {
        var kept: [ReplacementRule] = []
        var ids = Set<UUID>(), phrases = Set<String>()
        for var rule in decoded {
            guard kept.count < limit else { break }
            guard ReplacementRuleValidator.withinBounds(from: rule.from, to: rule.to),
                  phrases.insert(key(rule.from)).inserted else { continue }
            let original = rule.id.uuidString, phrase = key(rule.from)
            var attempt = 0
            while !ids.insert(rule.id).inserted {
                attempt += 1
                rule.id = derivedID("duplicate\u{1F}\(original)\u{1F}\(phrase)\u{1F}\(attempt)")
            }
            kept.append(rule)
        }
        return kept
    }

    /// Retired targets within the `to` length limit, one per folded target
    /// (the last stored wins, as `retire` keeps the newest), at most
    /// `retiredLimit`, newest kept.
    static func loadableRetired(_ decoded: [RetiredRuleTarget]) -> [RetiredRuleTarget] {
        var seen = Set<String>(), kept: [RetiredRuleTarget] = []
        for entry in decoded.reversed() {
            let key = TermDictionary.foldedKey(entry.to)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            kept.append(entry)
            if kept.count == retiredLimit { break }
        }
        return kept.reversed()
    }

    /// A UUID that depends only on `seed` (two FNV-1a 64-bit hashes, version
    /// and variant bits set as for an RFC 9562 v8 UUID). Not cryptographic:
    /// it only has to be stable and spread out; `loadable` re-checks
    /// uniqueness anyway.
    static func derivedID(_ seed: String) -> UUID {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325, b: UInt64 = 0x6c62_272e_07bb_0142
        for byte in seed.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            b = (b ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            b ^= b >> 29
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: a >> UInt64(8 * i))
            bytes[8 + i] = UInt8(truncatingIfNeeded: b >> UInt64(8 * i))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// One stored rule; a malformed one decodes to nil instead of failing the list.
struct LossyReplacementRule: Decodable {
    let rule: ReplacementRule?
    init(from decoder: Decoder) throws { rule = try? ReplacementRule(from: decoder) }
}

/// One stored retired target, decoded with the same raw size bound as a
/// rule's `to`; a malformed one decodes to nil.
struct LossyRetiredTarget: Decodable {
    private enum CodingKeys: String, CodingKey { case to, retiredAt }
    let target: RetiredRuleTarget?
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let to = try? c.decode(String.self, forKey: .to),
              ReplacementRuleValidator.rawWithinSize(to, max: ReplacementRuleValidator.maxToLength),
              let date = try? c.decode(Date.self, forKey: .retiredAt) else { target = nil; return }
        target = RetiredRuleTarget(to: to, retiredAt: date)
    }
}
