import Foundation

/// User-supplied vocabulary: names, jargon, and product names that speech
/// models mangle phonetically. Engines with prompt support use it to bias ASR;
/// every engine can use it to repair spellings during cleanup.
public struct TermDictionary: Codable, Sendable, Equatable {
    public var terms: [String]

    public init(terms: [String] = []) {
        self.terms = terms
    }

    public var isEmpty: Bool { normalizedTerms.isEmpty }

    /// Trimmed, de-duplicated, order-preserving.
    public var normalizedTerms: [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Prompt text conditioning Whisper's decoder toward these spellings.
    ///
    /// Phrased as a full sentence a real transcript could plausibly contain,
    /// not a "Label: term, term" list. Whisper's prompt is prior *transcript*
    /// text the decoder continues from, and "Label:" is exactly the shape of
    /// a speaker-label line in the subtitle/interview data it trained on —
    /// observed in the wild turning into a hallucinated name or fragment of
    /// the word "Glossary" pasted onto the front of real dictation (e.g. a
    /// transcript starting "Grzegorz:" or "Glosary C:" with no such word ever
    /// spoken). A natural sentence with no label-like colon at its start
    /// doesn't invite that continuation.
    public func asrPrompt(maxCharacters: Int = 800) -> String? {
        let terms = normalizedTerms
        guard !terms.isEmpty else { return nil }

        var included: [String] = []
        var length = 0
        for term in terms {
            let cost = term.count + 2
            if length + cost > maxCharacters { break }
            included.append(term)
            length += cost
        }
        guard !included.isEmpty else { return nil }
        return "This recording may mention \(Self.naturalList(included))."
    }

    /// "a", "a and b", or "a, b, and c" — deterministic regardless of the
    /// user's system locale, unlike `ListFormatter`, so the prompt this feeds
    /// to the decoder doesn't silently change shape across machines.
    private static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    /// Term list injected into the cleanup prompt so the LLM can fix spellings
    /// the decoder got wrong.
    public func cleanupHint() -> String? {
        let terms = normalizedTerms
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }

    /// Fixes ASR mishearings of vocabulary terms directly in the transcript,
    /// entirely locally and independent of the editing pass.
    ///
    /// Parakeet has no decoder-prompt path at all, so without this, a term
    /// only ever had a chance to be corrected when editing was enabled — with
    /// it off, the vocabulary silently did nothing. This runs unconditionally
    /// right after transcription, before editing, so a corrected spelling
    /// benefits both the raw transcript and whatever editing does with it.
    ///
    /// Purely local string matching, no network or model call: folds away
    /// case, diacritics, and spacing, then looks for a close match at each
    /// word position (and a one-word-wider or narrower window, since the
    /// model may have merged or split a term into a different number of
    /// words than it was typed). The allowed edit distance scales with term
    /// length, so short terms only ever match exactly — a two- or
    /// three-letter term fuzzy-matching half the words in a sentence would
    /// make this worse than doing nothing.
    public func applyCorrections(to text: String) -> String {
        let terms = normalizedTerms
        guard !terms.isEmpty, !text.isEmpty else { return text }

        let candidates = terms
            .compactMap { term -> Candidate? in
                let key = Self.foldedKey(term)
                guard !key.isEmpty else { return nil }
                return Candidate(term: term, key: key, wordCount: term.split(separator: " ").count)
            }
            .sorted { $0.key.count > $1.key.count }
        guard !candidates.isEmpty else { return text }

        let tokens = Self.tokenize(text)
        var result = ""
        var index = 0

        while index < tokens.count {
            var matchedTerm: String?
            var matchedSize = 1

            candidateLoop: for candidate in candidates {
                let sizes = Set([candidate.wordCount - 1, candidate.wordCount, candidate.wordCount + 1])
                    .filter { $0 > 0 }
                    .sorted()
                for size in sizes {
                    guard index + size <= tokens.count else { continue }
                    let windowKey = Self.foldedKey(
                        tokens[index..<(index + size)].map(\.word).joined(separator: " ")
                    )
                    guard !windowKey.isEmpty else { continue }

                    let distance = windowKey == candidate.key ? 0 : Self.levenshteinDistance(windowKey, candidate.key)
                    if distance <= Self.maxAllowedDistance(forKeyLength: candidate.key.count) {
                        matchedTerm = candidate.term
                        matchedSize = size
                        break candidateLoop
                    }
                }
            }

            if let matchedTerm {
                result += matchedTerm
                result += tokens[index + matchedSize - 1].trailing
                index += matchedSize
            } else {
                result += tokens[index].word
                result += tokens[index].trailing
                index += 1
            }
        }

        return result
    }

    private struct Candidate {
        let term: String
        let key: String
        let wordCount: Int
    }

    private struct Token {
        var word: String
        var trailing: String
    }

    /// Splits text into words paired with whatever non-word text follows
    /// them (spaces, punctuation), so the original text can be reassembled
    /// exactly when nothing in a span gets replaced.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var trailing = ""
        var inWord = false

        for character in text {
            if character.isLetter || character.isNumber {
                if !inWord, !word.isEmpty || !trailing.isEmpty {
                    tokens.append(Token(word: word, trailing: trailing))
                    word = ""
                    trailing = ""
                }
                word.append(character)
                inWord = true
            } else {
                trailing.append(character)
                inWord = false
            }
        }
        if !word.isEmpty || !trailing.isEmpty {
            tokens.append(Token(word: word, trailing: trailing))
        }
        return tokens
    }

    /// Lowercased, diacritic-folded, punctuation-stripped — so "Plainsay",
    /// "plain say", and "PlainSay" all fold to the same comparison key.
    private static func foldedKey(_ text: String) -> String {
        String(
            text
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(Character.init)
        )
    }

    /// A term this short matching half the words in a sentence would do more
    /// harm than good, so short terms only ever match when the fold is
    /// already exact; longer, more distinctive terms tolerate a growing
    /// number of substitutions.
    private static func maxAllowedDistance(forKeyLength length: Int) -> Int {
        switch length {
        case 0...3: 0
        case 4...5: 1
        case 6...9: 2
        default: 3
        }
    }

    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
