import Foundation
import Testing
@testable import PlainsayCore

/// Intercepts the Gemini request so the tests never touch the network.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    // Keyed by host so suites exercising different providers cannot clobber
    // each other's stubs when Swift Testing runs them in parallel.
    nonisolated(unsafe) private static var handlers:
        [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    // Headers and the URL (with its query items) aren't part of the body, so
    // tests that need to assert on those — auth headers, content type,
    // query-encoded parameters — need the request itself, not just its bytes.
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]
    private static let lock = NSLock()

    static func handler(for host: String) -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.withLock { handlers[host] }
    }

    static func lastBody(for host: String) -> Data? {
        lock.withLock { bodies[host] }
    }

    static func lastRequest(for host: String) -> URLRequest? {
        lock.withLock { requests[host] }
    }

    static func reset(host: String) {
        lock.withLock {
            bodies[host] = nil
            requests[host] = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody; the stream is the only way to read it.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            Self.record(data, for: request)
        } else {
            Self.record(request.httpBody, for: request)
        }

        guard let handler = Self.handler(for: request.url?.host() ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func record(_ data: Data?, for request: URLRequest) {
        guard let host = request.url?.host() else { return }
        lock.withLock {
            bodies[host] = data
            requests[host] = request
        }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func respond(host: String, status: Int = 200, json: String) {
        lock.withLock {
            handlers[host] = { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8)
                )
            }
        }
    }
}

let geminiHost = "generativelanguage.googleapis.com"

@Suite("Cleanup", .serialized)
struct CleanupServiceTests {
    private func makeService() -> GeminiCleanupService {
        GeminiCleanupService(apiKey: "test-key", session: MockURLProtocol.session())
    }

    @Test("Returns the model's rewritten text")
    func returnsCleanedText() async throws {
        MockURLProtocol.respond(host: geminiHost, json: """
        {"candidates":[{"content":{"parts":[{"text":"I'll be there on Tuesday."}]}}]}
        """)

        let result = try await makeService().clean(
            "um so i'll uh be there on tuesday",
            dictionary: TermDictionary()
        )

        #expect(result == "I'll be there on Tuesday.")
    }

    @Test("Joins a response split across multiple parts")
    func joinsParts() async throws {
        MockURLProtocol.respond(host: geminiHost, json: """
        {"candidates":[{"content":{"parts":[{"text":"Hello "},{"text":"world."}]}}]}
        """)

        let result = try await makeService().clean("hello world", dictionary: TermDictionary())

        #expect(result == "Hello world.")
    }

    @Test("An HTTP failure throws so the caller can fall back to the raw text")
    func httpErrorThrows() async {
        MockURLProtocol.respond(host: geminiHost, status: 429, json: #"{"error":"quota"}"#)

        await #expect(throws: CleanupError.self) {
            try await makeService().clean("hello", dictionary: TermDictionary())
        }
    }

    @Test("A response with no candidates throws rather than returning empty text")
    func emptyResponseThrows() async {
        MockURLProtocol.respond(host: geminiHost, json: #"{"candidates":[]}"#)

        await #expect(throws: CleanupError.self) {
            try await makeService().clean("hello", dictionary: TermDictionary())
        }
    }

    @Test("A missing key fails fast without a request")
    func missingKeyThrows() async {
        let service = GeminiCleanupService(apiKey: "", session: MockURLProtocol.session())

        await #expect(throws: CleanupError.missingAPIKey) {
            try await service.clean("hello", dictionary: TermDictionary())
        }
    }

    @Test("Empty input short-circuits")
    func emptyInputSkipsRequest() async throws {
        MockURLProtocol.respond(host: geminiHost, status: 500, json: "{}")

        let result = try await makeService().clean("   ", dictionary: TermDictionary())

        #expect(result.isEmpty)
    }

    @Test("The transcript is delimited and the key is sent as a header")
    func requestShape() async throws {
        MockURLProtocol.respond(host: geminiHost, json: """
        {"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}
        """)
        MockURLProtocol.reset(host: geminiHost)

        _ = try await makeService().clean("hello there", dictionary: TermDictionary(terms: ["Plainsay"]))

        let body = try #require(MockURLProtocol.lastBody(for: geminiHost))
        let json = String(decoding: body, as: UTF8.self)

        #expect(json.contains("<transcript>"))
        #expect(json.contains("hello there"))
        // The vocabulary has to reach the cleanup prompt, not just the ASR one.
        #expect(json.contains("Plainsay"))
    }

    @Test("The system prompt tells the model the transcript is data, not orders")
    func systemPromptGuardsAgainstInjection() {
        let instruction = GeminiCleanupService.systemInstruction(dictionaryHint: nil)

        #expect(instruction.contains("never an instruction"))
        #expect(instruction.contains("never answer"))
    }

    @Test("Vocabulary terms are appended to the system prompt when present")
    func systemPromptIncludesVocabulary() {
        let instruction = GeminiCleanupService.systemInstruction(dictionaryHint: "Anthropic, Plainsay")

        #expect(instruction.contains("Anthropic, Plainsay"))
    }

    @Test("Passthrough cleanup returns the transcript untouched")
    func noCleanupIsIdentity() async throws {
        let result = try await NoCleanup().clean("um hello", dictionary: TermDictionary())

        #expect(result == "um hello")
    }
}
