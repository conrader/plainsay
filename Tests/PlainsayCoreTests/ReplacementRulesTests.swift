import Foundation
import Testing
@testable import PlainsayCore

private func rules(_ pairs: [(String, String)]) -> ReplacementRuleSet {
    ReplacementRuleSet(rules: pairs.map { ReplacementRule(from: $0.0, to: $0.1) })
}

private func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

@Suite("Replacement rules: one-pass exact-phrase matcher")
struct ReplacementRuleMatcherTests {
    @Test("Whole words only; URLs, e-mail, handles, domains and file names stay")
    func boundaries() {
        let set = rules([("jason", "JSON")])
        #expect(set.apply(to: "Send the jason file.").text == "Send the JSON file.")
        #expect(set.apply(to: "Send the jason.").text == "Send the JSON.")
        #expect(set.apply(to: "jason, then jason").count == 2)
        for untouched in ["jasonette", "my_jason", "jason@example.com", "https://jason.dev",
                          "https://example.com/jason/x", "see jason.dev today", "open jason.txt",
                          "ping @jason", "v2.jason"] {
            let result = set.apply(to: untouched)
            #expect(result.text == untouched, "\(untouched)")
            #expect(result.count == 0, "\(untouched)")
        }
    }

    @Test("A phrase matches across spaces and tabs but never across a line break")
    func whitespace() {
        let set = rules([("plain say", "Plainsay")])
        #expect(set.apply(to: "I use plain  say daily").text == "I use Plainsay daily")
        #expect(set.apply(to: "I use plain\tsay daily").text == "I use Plainsay daily")
        #expect(set.apply(to: "I use plain\u{00A0}say daily").text == "I use Plainsay daily")
        for untouched in ["plain\nsay", "plain\r\nsay", "plain\n\nsay", "plain\u{2028}say"] {
            #expect(set.apply(to: untouched).count == 0, "\(untouched.debugDescription)")
        }
    }

    @Test("E-mail layout and translated output: line breaks around a match survive")
    func layout() {
        let set = rules([("jason", "JSON")])
        let mail = "Hi Anna,\n\nThe jason export is ready.\n\nBest,\nKonrad"
        #expect(set.apply(to: mail).text == "Hi Anna,\n\nThe JSON export is ready.\n\nBest,\nKonrad")
        let polish = "Cześć,\n\nplik jason jest gotowy."
        #expect(set.apply(to: polish).text == "Cześć,\n\nplik JSON jest gotowy.")
    }

    @Test("One pass: output is never rescanned")
    func onePass() {
        let set = rules([("alpha", "beta"), ("beta", "gamma")])
        let result = set.apply(to: "alpha beta")
        #expect(result.text == "beta gamma")
        #expect(result.count == 2)
    }

    @Test("Longest phrase wins at the same position")
    func longestFirst() {
        let set = rules([("claude", "Claude"), ("claude code", "Claude Code")])
        #expect(set.apply(to: "claude code and claude").text == "Claude Code and Claude")
        #expect(set.apply(to: "claude coder").text == "Claude coder")
    }

    @Test("Case: target verbatim, sentence-start capital kept, idempotent")
    func casing() {
        #expect(rules([("pyton", "python")]).apply(to: "Pyton is fun").text == "Python is fun")
        #expect(rules([("pyton", "python")]).apply(to: "I like pyton").text == "I like python")
        let iphone = rules([("iphone", "iPhone")])
        let once = iphone.apply(to: "IPHONE")
        #expect(once.text == "iPhone")
        let twice = iphone.apply(to: once.text)
        #expect(twice.text == "iPhone")
        #expect(twice.count == 0)
        #expect(rules([("jira", "Jira")]).apply(to: "Jira is open").count == 0)
    }

    @Test("Diacritic-sensitive: laska never touches łaska")
    func diacritics() {
        let set = rules([("laska", "Laska")])
        #expect(set.apply(to: "o łaskę i łaska").count == 0)
        #expect(set.apply(to: "laska").text == "Laska")
        #expect(rules([("Łukasz", "Łucjan")]).apply(to: "ŁUKASZ i łukasz").count == 2)
    }

    @Test("Polish inflection: only the exact form is replaced")
    func inflection() {
        let set = rules([("Kowalsky", "Kowalski")])
        #expect(set.apply(to: "Pan Kowalsky dzwonił.").text == "Pan Kowalski dzwonił.")
        #expect(set.apply(to: "Rozmawiałem z Kowalskyego.").count == 0)
        #expect(rules([("jason", "JSON")]).apply(to: "Rozmawiałem z Jasonem.").count == 0)
    }

    @Test("NFD text and NFD rules still match; untouched text keeps its bytes")
    func normalization() {
        let nfdText = "plik dz\u{0307}ejson jest gotowy"        // ż decomposed
        #expect(rules([("dżejson", "JSON")]).apply(to: nfdText).text == "plik JSON jest gotowy")
        #expect(rules([("dz\u{0307}ejson", "JSON")]).apply(to: "plik dżejson").text == "plik JSON")
        let unrelated = "zaz\u{0307}o\u{0301}łć gęślą jaźń"
        let result = rules([("jason", "JSON")]).apply(to: unrelated)
        #expect(result.count == 0)
        #expect(scalars(result.text) == scalars(unrelated))
    }

    @Test("Numbers inside times, decimals and versions are not split")
    func numericGuard() {
        let set = rules([("10", "ten")])
        #expect(set.apply(to: "Meet at 10:30, version 1.10, 10,5%").count == 0)
        #expect(set.apply(to: "I have 10 apples").text == "I have ten apples")
    }

    @Test("Disabled rules and the master switch change nothing")
    func disabled() {
        var set = rules([("jason", "JSON")])
        set.setEnabled(false, id: set.rules[0].id)
        #expect(set.apply(to: "the jason file").count == 0)
        var off = rules([("jason", "JSON")])
        off.isEnabled = false
        let result = off.apply(to: "the jason file")
        #expect(result.text == "the jason file")
        #expect(result.count == 0)
        #expect(ReplacementRuleSet().apply(to: "the jason file").count == 0)
    }

    @Test("Editing: upsert by phrase key, limit, inverse lookup, remove")
    func editing() {
        var set = rules([("jason", "JSON")])
        let replaced = set.upsert(ReplacementRule(from: "  JASON ", to: "Json"))
        #expect(replaced)
        #expect(set.rules.count == 1)
        #expect(set.rule(forFrom: "jason")?.to == "Json")
        set.rules[0].to = "JSON"
        #expect(set.inverse(of: "JSON", "jason")?.id == set.rules[0].id)
        #expect(set.inverse(of: "json", "Jason") != nil)
        #expect(set.inverse(of: "jason", "JSON") == nil)
        var full = ReplacementRuleSet(rules: (0..<ReplacementRuleSet.limit).map {
            ReplacementRule(from: "term\($0)x", to: "Term\($0)X")
        })
        let appendedPastLimit = full.upsert(ReplacementRule(from: "another", to: "Another"))
        #expect(!appendedPastLimit)
        #expect(full.rules.count == ReplacementRuleSet.limit)
        let replacedAtLimit = full.upsert(ReplacementRule(from: "term0x", to: "TERM0X"))
        #expect(replacedAtLimit)
        set.remove(id: set.rules[0].id)
        #expect(set.rules.isEmpty)
    }
}
