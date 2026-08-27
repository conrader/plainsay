import Foundation

/// Cleanup via any `/v1/chat/completions` endpoint.
///
/// One client for OpenRouter, OpenAI, Groq, Together, a local Ollama, or
/// anything else speaking the same dialect — the differences between them are
/// a base URL, a key, and a model name.
public struct OpenAICompatibleCleanupService: TextCleaning {
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval
    /// OpenRouter asks for these so usage shows up attributed rather than
    /// anonymous. Harmless everywhere else.
    private let refererHeader: String?
    private let titleHeader: String?

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        timeout: TimeInterval = 8.0,
        refererHeader: String? = "https://plainsay.app",
        titleHeader: String? = "Plainsay",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.refererHeader = refererHeader
        self.titleHeader = titleHeader
        self.session = session
    }

    public func clean(_ transcript: String, dictionary: TermDictionary, style: CleanupStyle) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard !apiKey.isEmpty else { throw CleanupError.missingAPIKey }
        guard !model.isEmpty else { throw CleanupError.missingModel }
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw CleanupError.invalidEndpoint(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let refererHeader { request.setValue(refererHeader, forHTTPHeaderField: "HTTP-Referer") }
        if let titleHeader { request.setValue(titleHeader, forHTTPHeaderField: "X-Title") }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // Without this, OpenRouter defaults to the model's full context
            // (tens of thousands of tokens) and its preflight affordability
            // check rejects that against a capped key, even though the actual
            // output is a small fraction of it.
            "max_tokens": max(1024, trimmed.count),
            "messages": [
                ["role": "system", "content": CleanupPrompt.systemInstruction(dictionaryHint: dictionary.cleanupHint(), style: style)],
                ["role": "user", "content": CleanupPrompt.userMessage(trimmed)],
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

        guard let http = response as? HTTPURLResponse else { throw CleanupError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CleanupError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        if Self.wasTruncated(data) { throw CleanupError.truncated }

        guard let text = Self.extractText(from: data) else { throw CleanupError.emptyResponse }
        return text
    }

    /// True when the choice ended because it ran out of budget. Every endpoint
    /// in this dialect reports that as `finish_reason: "length"`, and every one
    /// of them still answers 200 with the partial text.
    static func wasTruncated(_ data: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let reason = choices.first?["finish_reason"] as? String
        else { return false }
        return reason == "length"
    }

    static func extractText(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { return nil }

        // Reasoning models may return content as an array of parts rather than
        // a bare string.
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        } else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
