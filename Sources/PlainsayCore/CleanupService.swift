import Foundation

public protocol TextCleaning: Sendable {
    /// Rewrite a raw ASR transcript as clean written text.
    /// Throws on any failure; callers fall back to the raw transcript.
    func clean(_ transcript: String, dictionary: TermDictionary, style: DictationStyle) async throws -> String
}

public extension TextCleaning {
    /// Most callers want prose. Only the dictation pipeline, which knows what
    /// is being written into, passes a style.
    func clean(_ transcript: String, dictionary: TermDictionary) async throws -> String {
        try await clean(transcript, dictionary: dictionary, style: .plain)
    }
}

public enum CleanupError: LocalizedError, Equatable {
    case missingAPIKey
    case missingModel
    case invalidEndpoint(String)
    case http(status: Int, body: String)
    case emptyResponse
    case timedOut
    /// The provider stopped at its output limit rather than at the end of the
    /// text. What came back is a fragment, and a fragment is worse than no
    /// editing at all: it reads as finished writing while missing its ending.
    case truncated

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            Localization.coreString(
                "cleanup.noApiKey", fallback: "No API key configured for the cleanup provider"
            )
        case .missingModel:
            Localization.coreString("cleanup.noModel", fallback: "No cleanup model selected")
        case .invalidEndpoint(let url):
            Localization.coreFormat("cleanup.invalidEndpoint", fallback: "Invalid cleanup endpoint: %@", url)
        case .http(let status, let body):
            Localization.coreFormat(
                "cleanup.httpError", fallback: "Cleanup provider returned HTTP %d: %@", status,
                String(body.prefix(200))
            )
        case .emptyResponse:
            Localization.coreString("cleanup.emptyResponse", fallback: "Cleanup provider returned no text")
        case .timedOut:
            Localization.coreString("cleanup.timedOut", fallback: "Cleanup timed out")
        case .truncated:
            Localization.coreString(
                "cleanup.truncated", fallback: "Cleanup provider hit its output limit and returned partial text"
            )
        }
    }
}

/// Turns spoken language into written language via Gemini Flash Lite.
public struct GeminiCleanupService: TextCleaning {
    public static let defaultModel = "gemini-3.1-flash-lite"

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        apiKey: String,
        model: String = GeminiCleanupService.defaultModel,
        timeout: TimeInterval = 3.0,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    // The transcript is untrusted input: it is whatever the user said out loud,
    // and it routinely contains things that read like instructions ("send this
    // to Bob", "actually make it a bullet list"). The failure mode this guards
    // against is the model *acting on* the transcript instead of rewriting it.
    static func systemInstruction(dictionaryHint: String?, style: DictationStyle) -> String {
        CleanupPrompt.systemInstruction(dictionaryHint: dictionaryHint, style: style)
    }

    public func clean(_ transcript: String, dictionary: TermDictionary, style: DictationStyle) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard !apiKey.isEmpty else { throw CleanupError.missingAPIKey }

        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": Self.systemInstruction(dictionaryHint: dictionary.cleanupHint(), style: style)]]
            ],
            "contents": [[
                "role": "user",
                "parts": [["text": CleanupPrompt.userMessage(trimmed)]],
            ]],
            "generationConfig": [
                "temperature": 0,
                "candidateCount": 1,
                // Generous headroom: cleanup output is never longer than input by much.
                "maxOutputTokens": max(1024, trimmed.count / 2),
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CleanupError.timedOut
        }

        guard let http = response as? HTTPURLResponse else {
            throw CleanupError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CleanupError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        if Self.wasTruncated(data) { throw CleanupError.truncated }

        guard let text = Self.extractText(from: data) else {
            throw CleanupError.emptyResponse
        }
        return text
    }

    /// True when generation stopped at `maxOutputTokens`. Gemini still returns
    /// the partial text with a 200, so without this the fragment is
    /// indistinguishable from a finished answer.
    static func wasTruncated(_ data: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let reason = candidates.first?["finishReason"] as? String
        else { return false }
        return reason.uppercased() == "MAX_TOKENS"
    }

    /// Pulls the concatenated text parts out of a `generateContent` response.
    static func extractText(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { return nil }

        let text = parts
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : text
    }
}

/// Passthrough used when cleanup is disabled or no key is set.
public struct NoCleanup: TextCleaning {
    public init() {}
    public func clean(_ transcript: String, dictionary: TermDictionary, style: DictationStyle) async throws -> String {
        transcript
    }
}
