import Foundation
import Testing
@testable import PlainsayCore

@Suite("Vocabulary")
struct TermDictionaryTests {
    @Test("Blank and duplicate terms are dropped, first spelling wins")
    func normalization() {
        let dictionary = TermDictionary(terms: [
            "  Claude Code  ", "", "   ", "claude code", "WhisperKit",
        ])

        #expect(dictionary.normalizedTerms == ["Claude Code", "WhisperKit"])
    }

    @Test("An empty vocabulary produces no prompt at all")
    func emptyProducesNoPrompt() {
        #expect(TermDictionary().asrPrompt() == nil)
        #expect(TermDictionary(terms: ["  "]).cleanupHint() == nil)
    }

    @Test("The ASR prompt reads as prose, not a label the decoder can echo")
    func asrPromptShape() throws {
        // Not "Glossary: Anthropic, Gemini." — a colon-led label line is
        // exactly the shape of a speaker-label line in the subtitle data
        // Whisper trained on, and it was observed pasting a garbled version
        // of "Glossary" onto real dictations as a fake name/prefix.
        let prompt = try #require(TermDictionary(terms: ["Anthropic", "Gemini"]).asrPrompt())

        #expect(prompt == "This recording may mention Anthropic and Gemini.")
        #expect(!prompt.contains(":"))
    }

    @Test("Three or more terms join with a serial comma, not just 'and'")
    func asrPromptJoinsThreeOrMore() throws {
        let prompt = try #require(TermDictionary(terms: ["Anthropic", "Gemini", "OpenRouter"]).asrPrompt())

        #expect(prompt == "This recording may mention Anthropic, Gemini, and OpenRouter.")
    }

    @Test("A single term reads as a plain sentence")
    func asrPromptSingleTerm() throws {
        #expect(TermDictionary(terms: ["Plainsay"]).asrPrompt() == "This recording may mention Plainsay.")
    }

    @Test("The ASR prompt is capped so it cannot crowd out the audio context")
    func asrPromptIsTruncated() throws {
        let many = (0..<500).map { "Term\($0)" }
        let prompt = try #require(TermDictionary(terms: many).asrPrompt(maxCharacters: 100))

        #expect(prompt.count <= 140)
        #expect(prompt.contains("Term0, Term1"))
    }

    @Test("The cleanup hint lists every term")
    func cleanupHint() throws {
        let hint = try #require(TermDictionary(terms: ["Plainsay", "Whisper"]).cleanupHint())

        #expect(hint == "Plainsay, Whisper")
    }

    @Test("An empty dictionary or empty text leaves the transcript untouched")
    func correctionsNoOpWhenNothingToDo() {
        #expect(TermDictionary().applyCorrections(to: "hello there") == "hello there")
        #expect(TermDictionary(terms: ["Plainsay"]).applyCorrections(to: "") == "")
    }

    @Test("A correctly-spelled term gets re-cased to the dictionary's spelling")
    func correctionsFixCasing() {
        let dictionary = TermDictionary(terms: ["Plainsay"])

        #expect(dictionary.applyCorrections(to: "I love plainsay so much") == "I love Plainsay so much")
    }

    @Test("A one-word term the model split into two words gets merged back")
    func correctionsMergeSplitWord() {
        // Parakeet has no decoder prompt, so a made-up word like "Plainsay"
        // reliably comes out as two real words instead.
        let dictionary = TermDictionary(terms: ["Plainsay"])

        #expect(dictionary.applyCorrections(to: "I use plain say daily.") == "I use Plainsay daily.")
    }

    @Test("A multi-word term still merges across a wider window")
    func correctionsMergeMultiWordTerm() {
        let dictionary = TermDictionary(terms: ["Plainsay Cloud"])

        #expect(
            dictionary.applyCorrections(to: "I subscribed to plain say cloud yesterday")
                == "I subscribed to Plainsay Cloud yesterday"
        )
    }

    @Test("A close phonetic mishearing within tolerance is corrected")
    func correctionsFixCloseMishearing() {
        let dictionary = TermDictionary(terms: ["Anthropic"])

        #expect(dictionary.applyCorrections(to: "I asked Anthropik about it") == "I asked Anthropic about it")
    }

    @Test("An unrelated word is left alone rather than over-corrected")
    func correctionsDoNotOverfire() {
        let dictionary = TermDictionary(terms: ["Anthropic"])

        #expect(dictionary.applyCorrections(to: "I saw an octopus today") == "I saw an octopus today")
    }

    @Test("A short term only ever matches an exact fold, never fuzzily")
    func correctionsRequireExactMatchForShortTerms() {
        // "AI" is one edit away from "hi" — fuzzy-matching a two-letter term
        // would rewrite ordinary words throughout a transcript.
        let dictionary = TermDictionary(terms: ["AI"])

        #expect(dictionary.applyCorrections(to: "hi there") == "hi there")
    }
}

@Suite("Transcript normalization")
struct TranscriptNormalizationTests {
    @Test("Whisper's sound annotations are stripped")
    func stripsAnnotations() {
        #expect(normalizeTranscript("[BLANK_AUDIO]") == "")
        #expect(normalizeTranscript("(upbeat music)") == "")
        #expect(normalizeTranscript("♪ la la ♪") == "")
        #expect(normalizeTranscript("  [INAUDIBLE] hello there ") == "hello there")
    }

    @Test("Collapses the whitespace left behind by stripping")
    func collapsesWhitespace() {
        #expect(normalizeTranscript("hello   [noise]   world") == "hello world")
    }

    @Test("Real speech that looks like a hallucination is kept")
    func doesNotEatRealSpeech() {
        // Whisper hallucinates these on silence, but people also dictate them,
        // and losing a real dictation is the worse failure.
        #expect(normalizeTranscript("Thank you.") == "Thank you.")
        #expect(normalizeTranscript("you") == "you")
    }
}

@Suite("Signal detection")
struct SignalDetectionTests {
    @Test("Digital silence has no signal")
    func silenceHasNoSignal() {
        #expect(!WhisperKitEngine.hasSignal([Float](repeating: 0, count: 16_000)))
    }

    @Test("Quiet but audible speech counts as signal")
    func quietSpeechHasSignal() {
        // 0.11 peak is what a real close-mic dictation measured at, and it was
        // being dropped as silence before the retry existed.
        var samples = [Float](repeating: 0.001, count: 16_000)
        samples[8_000] = 0.1136
        #expect(WhisperKitEngine.hasSignal(samples))
    }

    @Test("Room tone alone does not count as signal")
    func roomToneIsNotSignal() {
        #expect(!WhisperKitEngine.hasSignal([Float](repeating: 0.005, count: 16_000)))
    }
}

@Suite("Default vocabulary")
@MainActor
struct DefaultVocabularyTests {
    @Test("A fresh install already knows its own name")
    func plainsayIsSeededByDefault() {
        // Whisper mishears made-up words, and "Plainsay" is one — seeded so
        // a new user's first dictation of the app's own name spells correctly
        // without them having to notice and add it themselves.
        let defaults = UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: defaults)

        #expect(settings.dictionary.normalizedTerms.contains("Plainsay"))
    }

    @Test("An existing dictionary, even an empty one, is never overwritten")
    func existingDictionaryIsRespected() {
        let defaults = UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!
        // Simulate a returning user who already saved an empty dictionary —
        // decode() must not treat that key as absent and fall back to seeding.
        let first = PlainsaySettings(defaults: defaults)
        first.dictionary = TermDictionary(terms: [])

        let second = PlainsaySettings(defaults: defaults)
        #expect(second.dictionary.normalizedTerms.isEmpty)
    }
}
