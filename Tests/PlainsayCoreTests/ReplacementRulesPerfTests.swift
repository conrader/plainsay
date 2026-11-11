import Foundation
import Testing
import PlainsayCore

/// The 50 ms budget for applying the full rule set to one long dictation.
///
/// Workload (identical to `ReplacementRulesCorpusTests.performance`): 200
/// two-word rules `projekt<i> nazwa → Projekt<i>Nazwa`, the 76-character
/// sentence below repeated 316 times (24,016 characters). One rule fires in
/// every sentence; the sentence also carries a time and a file name so the
/// boundary guards and the protected-span pass run.
///
/// Method: each sample is one full `apply(to:)` call, which normalizes the
/// rules, compiles the regex and scans the text, so nothing is cached between
/// samples. The first sample (`cold`) is reported separately, then 21 more;
/// the budget applies to their median, which is stable against a stray
/// scheduler hiccup. Run it alone for a clean figure; the full suite runs
/// tests in parallel.
///
///     swift test --filter ReplacementRulesPerfTests              # debug
///     swift test -c release --filter ReplacementRulesPerfTests   # release
@Suite("Replacement rules: performance budget", .serialized)
struct ReplacementRulesPerfTests {
    static let budget = Duration.milliseconds(50)
    static let samples = 21
    static let sentence = "Spotkajmy się we wtorek o 10:30, plik jason.txt i projekt7 nazwa są gotowe. "

    static func workloadRules() -> ReplacementRuleSet {
        ReplacementRuleSet(rules: (0..<ReplacementRuleSet.limit).map {
            ReplacementRule(from: "projekt\($0) nazwa", to: "Projekt\($0)Nazwa")
        })
    }

    static func workloadText() -> String {
        String(repeating: sentence, count: 24_000 / sentence.count + 1)
    }

    private static func milliseconds(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
        return String(format: "%.2f", ms)
    }

    @Test("200 rules over 24,016 characters: median apply under 50 ms")
    func budgetHolds() {
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let set = Self.workloadRules()
        let text = Self.workloadText()
        let expected = String(repeating: Self.sentence.replacingOccurrences(of: "projekt7 nazwa", with: "Projekt7Nazwa"),
                              count: 24_000 / Self.sentence.count + 1)
        #expect(set.rules.count == 200)
        #expect(text.count == 24_016)

        let clock = ContinuousClock()
        var durations: [Duration] = []
        for _ in 0...Self.samples {
            var result = (text: "", count: 0)
            durations.append(clock.measure { result = set.apply(to: text) })
            #expect(result.count == 316)
            #expect(result.text == expected)
        }
        let cold = durations.removeFirst()
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        print("REPLACEMENT_RULES_PERF_STATS config=\(configuration) rules=\(set.rules.count) chars=\(text.count)"
              + " samples=\(sorted.count) cold_ms=\(Self.milliseconds(cold)) min_ms=\(Self.milliseconds(sorted[0]))"
              + " median_ms=\(Self.milliseconds(median)) max_ms=\(Self.milliseconds(sorted[sorted.count - 1]))"
              + " budget_ms=\(Self.milliseconds(Self.budget))")
        #expect(median < Self.budget, "median \(median) over the \(Self.budget) budget (\(configuration))")
    }
}
