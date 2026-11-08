import Foundation
import Testing
@testable import PlainsayCore

/// The matcher as first written (commit e4abd56): one regex with a capture
/// group per rule and the gap spelled `[\p{Zs}\t]+`. Kept verbatim as the
/// behavioural reference for the optimized `ReplacementMatcher`.
private func referenceApply(_ set: ReplacementRuleSet, to text: String) -> (text: String, count: Int) {
    guard set.isEnabled else { return (text, 0) }
    var seen = Set<String>()
    let active = set.rules
        .filter { $0.isEnabled }
        .map { (from: $0.from.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines),
                to: $0.to.precomposedStringWithCanonicalMapping) }
        .filter { !$0.from.isEmpty && seen.insert(ReplacementRuleSet.key($0.from)).inserted }
        .sorted { lhs, rhs in
            let l = lhs.from.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let r = rhs.from.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return l.count != r.count ? l.count > r.count : l < r
        }
    guard !active.isEmpty else { return (text, 0) }

    let alternatives = active.map { rule in
        "(" + rule.from.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"[\p{Zs}\t]+"#) + ")"
    }
    let pattern = ReplacementRuleSet.before + "(?:" + alternatives.joined(separator: "|") + ")" + ReplacementRuleSet.after
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
        let replacement = ReplacementRuleSet.cased(active[index - 1].to, like: matched)
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

/// Deterministic generator (SplitMix64), so a failure reproduces by seed.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

@Suite("Replacement rules: optimized matcher equals the reference")
struct ReplacementRulesReferenceTests {
    /// Words chosen to stress what the optimization touches: ASCII vs
    /// non-ASCII lookup, case folding that ICU and Swift may treat
    /// differently (ß/ss, ſ, Kelvin sign, İ, ligatures), NFD input,
    /// shared prefixes and the boundary guards.
    private static let words = [
        "jason", "JSON", "Jason", "json", "plain", "say", "claude", "code", "coder",
        "kowalsky", "Kowalski", "dżejson", "dz\u{0307}ejson", "łaska", "laska", "ŁUKASZ", "łukasz",
        "straße", "STRASSE", "strasse", "ſtar", "star", "\u{212A}elvin", "kelvin", "İstanbul", "istanbul",
        "ﬀ", "ff", "10", "1.10", "10:30", "jira", "Jira", "iphone", "IPHONE", "projekt7", "nazwa",
        "a", "A", "x", "c++", "node.js", "é", "e\u{0301}",
    ]
    private static let gaps = [" ", " ", " ", "  ", "\t", "\u{00A0}", "\u{2009}", "\u{3000}", "\n", "\r\n", "\u{2028}"]
    private static let punctuation = ["", "", "", ",", ".", "!", "?", ":", "-", "/", "@", "_", "(", ")", "'"]
    private static let fragments = ["https://jason.dev/a", "jason@example.com", "@jason", "jason.txt", "v2.jason",
                                    "$125", "3,5 %", "my_jason", "jasonette", "Rozmawiałem z Jasonem."]

    private static func phrase(_ rng: inout SplitMix) -> String {
        (0..<(1 + rng.below(3))).map { _ in rng.pick(words) }.joined(separator: rng.pick([" ", " ", "\t", "  "]))
    }

    private static func text(_ rng: inout SplitMix) -> String {
        var out = ""
        for _ in 0..<(4 + rng.below(28)) {
            out += rng.below(8) == 0 ? rng.pick(fragments) : rng.pick(words)
            out += rng.pick(punctuation)
            out += rng.pick(gaps)
        }
        return out
    }

    private static func ruleSet(_ rng: inout SplitMix) -> ReplacementRuleSet {
        let rules = (0..<(1 + rng.below(12))).map { _ in
            ReplacementRule(from: (rng.below(6) == 0 ? "  " : "") + phrase(&rng), to: phrase(&rng),
                            isEnabled: rng.below(10) != 0)
        }
        return ReplacementRuleSet(rules: rules)
    }

    @Test("1,500 seeded random rule sets and texts give identical output and counts")
    func randomized() {
        var rng = SplitMix(state: 0x5EED_2026_1108)
        var fired = 0
        for case_ in 0..<1_500 {
            let set = Self.ruleSet(&rng)
            let text = Self.text(&rng)
            let expected = referenceApply(set, to: text)
            let actual = set.apply(to: text)
            if expected.count > 0 { fired += 1 }
            #expect(Array(actual.text.unicodeScalars) == Array(expected.text.unicodeScalars),
                    "case \(case_): \(set.rules.map { "\($0.from)→\($0.to)" }) on \(text.debugDescription)")
            #expect(actual.count == expected.count, "case \(case_)")
        }
        // The generator must actually exercise replacements, not only misses.
        #expect(fired > 500)
    }

    @Test("The 200-rule performance workload matches the reference")
    func performanceWorkload() {
        let set = ReplacementRulesPerfTests.workloadRules()
        let text = ReplacementRulesPerfTests.workloadText()
        let expected = referenceApply(set, to: text)
        let actual = set.apply(to: text)
        #expect(actual.text == expected.text)
        #expect(actual.count == expected.count)
    }

    @Test("Non-ASCII rules matching ASCII text, and ASCII rules matching non-ASCII text")
    func crossScriptFolding() {
        let cases: [([(String, String)], String)] = [
            ([("ſtar", "Star"), ("star", "STAR")], "a star and a ſtar"),
            ([("\u{212A}elvin", "K1"), ("kelvin", "K2")], "kelvin \u{212A}elvin KELVIN"),
            ([("strasse", "S1"), ("straße", "S2")], "straße STRASSE strasse"),
            ([("ﬀ", "L1"), ("ff", "L2")], "ff ﬀ FF"),
            ([("istanbul", "I1"), ("İstanbul", "I2")], "İstanbul istanbul ISTANBUL"),
            ([("jason", "JSON"), ("dżejson", "JSON")], "jason dz\u{0307}ejson Jason"),
        ]
        for (pairs, text) in cases {
            let set = ReplacementRuleSet(rules: pairs.map { ReplacementRule(from: $0.0, to: $0.1) })
            let expected = referenceApply(set, to: text)
            let actual = set.apply(to: text)
            #expect(Array(actual.text.unicodeScalars) == Array(expected.text.unicodeScalars), "\(pairs) on \(text)")
            #expect(actual.count == expected.count, "\(pairs) on \(text)")
        }
    }
}
