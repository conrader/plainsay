# Replacement rules: performance budget

Budget: one `ReplacementRuleSet.apply(to:)` call with the full rule set on a
long dictation takes **under 50 ms, in a debug build**.

## Workload

The workload is fixed, and the same in both perf tests:

- 200 rules (`ReplacementRuleSet.limit`), `projekt<i> nazwa → Projekt<i>Nazwa`.
  They are two-word phrases that all share a prefix, which is the worst case
  for the alternation.
- Text: `"Spotkajmy się we wtorek o 10:30, plik jason.txt i projekt7 nazwa są gotowe. "`
  (76 characters) repeated 316 times, giving 24,016 characters.
- Each sentence fires one rule (316 replacements). The time and the file name
  exercise the boundary guards and the URL/e-mail protected-span pass.

## Measurement

`ReplacementRulesPerfTests.budgetHolds` runs a full `apply` per sample: it
normalizes the rules, compiles the regex, scans the text and builds the
output. Nothing is cached between samples. It runs 1 cold sample and then 21
more, and checks each output against the expected text and count. It asserts
**median < 50 ms** and prints:

```
REPLACEMENT_RULES_PERF_STATS config=<debug|release> rules=200 chars=24016 samples=21 cold_ms=… min_ms=… median_ms=… max_ms=… budget_ms=50.00
```

The original spike test (`ReplacementRulesCorpusTests.performance`) is
unchanged. It still prints one cold sample as `REPLACEMENT_RULES_PERF … elapsed=…`.

swift-testing runs tests in parallel, so run the perf test alone for a clean
figure:

```sh
swift test --filter ReplacementRulesPerfTests              # debug
swift test -c release --filter ReplacementRulesPerfTests   # release
```

## What changed (`Sources/PlainsayCore/ReplacementMatcher.swift`)

Profile of the original on the workload (Linux, Swift 6.0.3, debug, ~92 ms total):

| Step | ms |
|---|---|
| Splicing 316 replacements into an NSMutableString, back to front | ~30 |
| Per-match work and scanning with 200 capture groups | ~43 (scan alone 14) |
| Regex compile, of which `[\p{Zs}\t]` ×200 was ~10 | ~10 |
| Rule sort that re-split strings inside the comparator | ~5 |
| Protected spans (`StructuredDetails`) | ~4 |

Fixes, all keeping the original semantics:

1. Rules are normalized, split and keyed once, and sorted on precomputed keys.
2. The scan regex has no capture groups, so the matches are the same and the
   scan is ~3× faster. The rule behind each distinct matched string is found
   once and memoized. ASCII text is resolved by exact lookup. Otherwise an
   anchored regex over all rules, in the original order, decides.
3. The output is built front to back in one pass.
4. The phrase gap is `\h+`. ICU defines `\h` as `[\p{Zs}\t]` but tests it
   without building a property set. Checked over all 1,114,112 code points:
   18 matched, 0 differences.

`ReplacementRulesReferenceTests` keeps the original implementation verbatim.
It compares output and count on 1,500 seeded random rule sets and texts, on
the perf workload and on cross-script case-folding cases (ß/ss, ſ, Kelvin
sign, İ, ﬀ, NFD). On the Mac this also checks equivalence under Apple's ICU.

## Results

| Where | Config | Before | After |
|---|---|---|---|
| Mac (spike job) | debug | 87 ms (1 cold sample) | pending the Mac job |
| Linux x86_64, Swift 6.0.3, swift-corelibs-foundation ICU | debug | 80–108 ms | median 18–19 ms, cold 18–28 ms |
| Linux, same | release | — | median 17–20 ms, cold 20–27 ms |

Release is barely faster than debug: what remains runs inside ICU and
Foundation, which are optimized builds in both configurations.
