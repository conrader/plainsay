import Foundation

/// A vocabulary term worth offering, mined from what the speaker has already
/// dictated.
public struct DictionaryProposal: Equatable, Sendable, Identifiable {
    /// The spelling to offer, taken from the transcript it was found in.
    public let term: String
    /// How many separate dictations it turned up in.
    public let occurrences: Int

    public var id: String { term.lowercased() }

    public init(term: String, occurrences: Int) {
        self.term = term
        self.occurrences = occurrences
    }
}

/// Builds the vocabulary from the speaker's own dictation history instead of
/// asking them to think of their jargon in the abstract.
///
/// An empty dictionary is the common case, because remembering every product
/// name and surname you say out loud — before you have seen any of them go
/// wrong — is not something anyone actually does. The names are already in the
/// history, though: they are the words that keep coming back.
///
/// Nothing here edits the dictionary. Every term is a proposal the speaker
/// accepts or dismisses, because a vocabulary that adds itself would start
/// rewriting transcripts on its own guess about what matters — which is the
/// failure the matching side of this had to be pulled back from.
public enum DictionaryProposer {
    /// Terms recurring across `minimumOccurrences` or more separate
    /// dictations, most frequent first.
    ///
    /// - Parameters:
    ///   - records: dictation history, newest or oldest order is irrelevant.
    ///   - existing: terms already in the vocabulary, never proposed again.
    ///   - minimumOccurrences: two, because history keeps only the last
    ///     hundred dictations and a higher bar leaves almost nothing to
    ///     offer. These are proposals, so the cost of a weak one is a
    ///     dismissal, while the cost of never surfacing a real term is a
    ///     vocabulary that stays empty forever.
    public static func propose(
        from records: [TranscriptRecord],
        existing: TermDictionary = TermDictionary(),
        minimumOccurrences: Int = 2,
        limit: Int = 12
    ) -> [DictionaryProposal] {
        guard minimumOccurrences > 0, limit > 0 else { return [] }

        let known = Set(existing.normalizedTerms.map { Self.fold($0) })

        // Counted per dictation, not per mention: a word said five times in
        // one sentence is a single piece of evidence about the speaker's
        // vocabulary, whereas the same word across five different dictations
        // is five.
        var recordsContaining: [String: Int] = [:]
        var spellings: [String: String] = [:]

        for record in records {
            let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            var seenHere = Set<String>()
            for word in Self.candidateWords(in: text) {
                let key = Self.fold(word)
                guard !key.isEmpty, !known.contains(key) else { continue }
                // First spelling encountered wins, so the proposal reads the
                // way the speaker's own transcript did.
                if spellings[key] == nil { spellings[key] = word }
                seenHere.insert(key)
            }
            for key in seenHere { recordsContaining[key, default: 0] += 1 }
        }

        let frequent = recordsContaining.filter { $0.value >= minimumOccurrences }
        var proposals: [DictionaryProposal] = []
        for (key, count) in frequent {
            guard let spelling = spellings[key] else { continue }
            proposals.append(DictionaryProposal(term: spelling, occurrences: count))
        }
        proposals.sort { left, right in
            if left.occurrences != right.occurrences { return left.occurrences > right.occurrences }
            return left.term.localizedCaseInsensitiveCompare(right.term) == .orderedAscending
        }
        return Array(proposals.prefix(limit))
    }

    /// Words that look like a name rather than ordinary prose.
    ///
    /// Two shapes qualify. A capital inside the word ("WhisperKit", "OpenAI")
    /// is unambiguous — no ordinary word is spelled that way, so position in
    /// the sentence does not matter. A leading capital only counts away from
    /// the start of a sentence, because every sentence begins with one and
    /// proposing the first word of each would bury the real names.
    static func candidateWords(in text: String) -> [String] {
        var found: [String] = []
        var word = ""
        var atSentenceStart = true

        func flush() {
            let current = word
            word = ""
            guard !current.isEmpty else { return }
            let wasSentenceStart = atSentenceStart
            atSentenceStart = false
            guard isCandidate(current, atSentenceStart: wasSentenceStart) else { return }
            found.append(current)
        }

        for character in text {
            if character.isLetter || character == "'" || character == "-" {
                word.append(character)
            } else {
                flush()
                if character == "." || character == "!" || character == "?" || character == "\n" {
                    atSentenceStart = true
                }
            }
        }
        flush()
        return found
    }

    static func isCandidate(_ word: String, atSentenceStart: Bool) -> Bool {
        guard word.count >= 3, word.count <= 40 else { return false }
        guard let first = word.first, first.isUppercase else { return false }
        // A digit inside a word makes it a version or an identifier, not
        // vocabulary worth biasing a decoder toward.
        guard !word.contains(where: { $0.isNumber }) else { return false }

        let hasInnerCapital = word.dropFirst().contains { $0.isUppercase }
        return hasInnerCapital || !atSentenceStart
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}
