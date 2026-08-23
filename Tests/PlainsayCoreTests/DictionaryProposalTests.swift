import Foundation
import Testing
@testable import PlainsayCore

@Suite("Vocabulary proposals")
struct DictionaryProposalTests {
    private func record(_ text: String) -> TranscriptRecord {
        TranscriptRecord(
            text: text,
            rawText: text,
            outcome: .inserted,
            durationSeconds: 4,
            targetApp: nil
        )
    }

    @Test("A name recurring across dictations is proposed")
    func recurringNameIsProposed() {
        let history = [
            record("We shipped it to OpenRouter this morning."),
            record("Ask OpenRouter about the quota."),
            record("The OpenRouter key expired."),
        ]

        let proposals = DictionaryProposer.propose(from: history)

        #expect(proposals.map(\.term) == ["OpenRouter"])
        #expect(proposals.first?.occurrences == 3)
    }

    @Test("A name from a single dictation is not proposed")
    func oneOffIsNotProposed() {
        let history = [record("We shipped it to OpenRouter this morning.")]

        #expect(DictionaryProposer.propose(from: history).isEmpty)
    }

    /// Repetition inside one dictation says the speaker was on a topic, not
    /// that the word is part of their working vocabulary.
    @Test("Repeats within one dictation count once")
    func repeatsWithinOneRecordCountOnce() {
        let history = [record("Kaseya and Kaseya and Kaseya again.")]

        #expect(DictionaryProposer.propose(from: history).isEmpty)
    }

    @Test("Terms already in the vocabulary are never proposed again")
    func knownTermsAreSkipped() {
        let history = [
            record("Plainsay handled it."),
            record("I opened Plainsay."),
            record("Plainsay again."),
        ]

        let proposals = DictionaryProposer.propose(
            from: history,
            existing: TermDictionary(terms: ["plainsay"])
        )

        #expect(proposals.isEmpty)
    }

    /// Every sentence starts with a capital, so proposing first words would
    /// bury the real names under "The", "This" and "Maybe".
    @Test("Ordinary words starting a sentence are not names")
    func sentenceStartsAreNotProposed() {
        let history = [
            record("Maybe we should ship."),
            record("Maybe not today."),
            record("Maybe later then."),
        ]

        #expect(DictionaryProposer.propose(from: history).isEmpty)
    }

    /// A capital inside the word is unambiguous, so position stops mattering.
    @Test("An inner capital counts even at the start of a sentence")
    func innerCapitalCountsAnywhere() {
        let history = [
            record("WhisperKit is loaded."),
            record("WhisperKit failed again."),
            record("WhisperKit is fine now."),
        ]

        #expect(DictionaryProposer.propose(from: history).map(\.term) == ["WhisperKit"])
    }

    @Test("Versions and identifiers are not vocabulary")
    func numbersAreRejected() {
        #expect(!DictionaryProposer.isCandidate("Sonoma14", atSentenceStart: false))
        #expect(!DictionaryProposer.isCandidate("Hi", atSentenceStart: false))
        #expect(DictionaryProposer.isCandidate("Kaseya", atSentenceStart: false))
    }

    @Test("The most frequent names come first, and the list is capped")
    func orderedAndCapped() {
        var history: [TranscriptRecord] = []
        for _ in 0..<5 { history.append(record("About Anthropic.")) }
        for _ in 0..<3 { history.append(record("About Gemini.")) }

        let proposals = DictionaryProposer.propose(from: history, limit: 1)

        #expect(proposals.map(\.term) == ["Anthropic"])
    }

    @Test("No history proposes nothing")
    func emptyHistory() {
        #expect(DictionaryProposer.propose(from: []).isEmpty)
    }
}
