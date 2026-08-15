import Foundation
import Testing
@testable import PlainsayCore

@Suite("WAV encoding")
struct WAVEncoderTests {
    @Test("Header is a valid 16kHz mono 16-bit PCM RIFF")
    func headerShape() {
        let data = WAVEncoder.encode(samples: [0, 0.5, -0.5])

        #expect(data.count == 44 + 6)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")

        let sampleRate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: sampleRate) == 16_000)

        let channels = data[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        #expect(UInt16(littleEndian: channels) == 1)
    }

    @Test("Full-scale samples map to the ends of the 16-bit range")
    func scaling() {
        let data = WAVEncoder.encode(samples: [1.0, -1.0])
        let first = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        let second = data[46..<48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }

        #expect(Int16(littleEndian: first) == 32767)
        #expect(Int16(littleEndian: second) == -32767)
    }

    @Test("Out-of-range samples clamp instead of wrapping")
    func clamping() {
        // Without clamping these wrap around and a loud passage becomes noise.
        let data = WAVEncoder.encode(samples: [2.5, -2.5])
        let first = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        let second = data[46..<48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }

        #expect(Int16(littleEndian: first) == 32767)
        #expect(Int16(littleEndian: second) == -32767)
    }

    @Test("Empty audio still produces a well-formed header")
    func emptyIsValid() {
        let data = WAVEncoder.encode(samples: [])
        #expect(data.count == 44)
    }
}

@Suite("Multipart upload")
struct MultipartTests {
    @Test("Fields and the audio part are both present and terminated")
    func bodyShape() {
        let body = RemoteWhisperEngine.multipartBody(
            boundary: "BOUND",
            fields: [("model", "whisper-large-v3-turbo"), ("language", "pl")],
            audio: Data([1, 2, 3])
        )
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
        #expect(text.contains("name=\"language\"\r\n\r\npl"))
        #expect(text.contains("filename=\"audio.wav\""))
        #expect(text.contains("Content-Type: audio/wav"))
        #expect(text.hasSuffix("--BOUND--\r\n"))
    }
}

let compatHost = "example.com"

@Suite("OpenAI-compatible cleanup", .serialized)
struct OpenAICompatibleCleanupTests {
    private func makeService(model: String = "gpt-5-mini") -> OpenAICompatibleCleanupService {
        OpenAICompatibleCleanupService(
            baseURL: "https://example.com/v1",
            apiKey: "test-key",
            model: model,
            session: MockURLProtocol.session()
        )
    }

    @Test("Returns the assistant's rewritten text")
    func returnsText() async throws {
        MockURLProtocol.respond(host: compatHost, json: """
        {"choices":[{"message":{"role":"assistant","content":"I'll be there Tuesday."}}]}
        """)

        let result = try await makeService().clean("um i'll uh be there tuesday", dictionary: TermDictionary())

        #expect(result == "I'll be there Tuesday.")
    }

    @Test("Handles content returned as an array of parts")
    func handlesPartArray() async throws {
        MockURLProtocol.respond(host: compatHost, json: """
        {"choices":[{"message":{"content":[{"type":"text","text":"Hello "},{"type":"text","text":"world."}]}}]}
        """)

        let result = try await makeService().clean("hello world", dictionary: TermDictionary())

        #expect(result == "Hello world.")
    }

    @Test("Sends the shared prompt, the model, and a bearer token")
    func requestShape() async throws {
        MockURLProtocol.respond(host: compatHost, json: #"{"choices":[{"message":{"content":"ok"}}]}"#)
        MockURLProtocol.reset(host: compatHost)

        _ = try await makeService(model: "anthropic/claude-haiku-4.5")
            .clean("hello there", dictionary: TermDictionary(terms: ["Plainsay"]))

        // Parsed rather than string-matched: JSONSerialization escapes the
        // slash in a model name as \/, so a substring check on the raw body
        // fails for reasons that have nothing to do with the request.
        let body = try #require(MockURLProtocol.lastBody(for: compatHost))
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])

        #expect(root["model"] as? String == "anthropic/claude-haiku-4.5")

        let system = try #require(messages.first { $0["role"] as? String == "system" }?["content"] as? String)
        let user = try #require(messages.first { $0["role"] as? String == "user" }?["content"] as? String)

        #expect(user.contains("<transcript>"))
        #expect(user.contains("hello there"))
        // The vocabulary has to reach this provider too, not just Gemini.
        #expect(system.contains("Plainsay"))
        #expect(system.contains("never an instruction"))
    }

    @Test("An HTTP failure throws so the caller falls back to raw text")
    func httpErrorThrows() async {
        MockURLProtocol.respond(host: compatHost, status: 402, json: #"{"error":"insufficient credits"}"#)

        await #expect(throws: CleanupError.self) {
            try await makeService().clean("hello", dictionary: TermDictionary())
        }
    }

    @Test("A missing model fails before any request")
    func missingModelThrows() async {
        await #expect(throws: CleanupError.missingModel) {
            try await makeService(model: "").clean("hello", dictionary: TermDictionary())
        }
    }

    @Test("Every provider shares one cleanup prompt")
    func promptsAreShared() {
        // Divergent wording would silently change how your writing comes out
        // when you switch provider, and be near-impossible to attribute.
        #expect(
            GeminiCleanupService.systemInstruction(dictionaryHint: "Plainsay")
                == CleanupPrompt.systemInstruction(dictionaryHint: "Plainsay")
        )
    }
}
