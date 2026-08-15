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

    @Test("The ASR prompt reads as prose, not a bare list")
    func asrPromptShape() throws {
        let prompt = try #require(TermDictionary(terms: ["Anthropic", "Gemini"]).asrPrompt())

        #expect(prompt == "Glossary: Anthropic, Gemini.")
    }

    @Test("The ASR prompt is capped so it cannot crowd out the audio context")
    func asrPromptIsTruncated() throws {
        let many = (0..<500).map { "Term\($0)" }
        let prompt = try #require(TermDictionary(terms: many).asrPrompt(maxCharacters: 100))

        #expect(prompt.count <= 120)
        #expect(prompt.hasPrefix("Glossary: Term0, Term1"))
    }

    @Test("The cleanup hint lists every term")
    func cleanupHint() throws {
        let hint = try #require(TermDictionary(terms: ["Plainsay", "Whisper"]).cleanupHint())

        #expect(hint == "Plainsay, Whisper")
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
