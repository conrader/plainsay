import Foundation

/// Cleanup via Anthropic's Messages API.
///
/// A separate implementation because Anthropic's API is not the OpenAI chat-
/// completions dialect `OpenAICompatibleCleanupService` speaks — different
/// auth header, a required version header, and system prompt as a top-level
/// field rather than a message.
public struct AnthropicCleanupService: TextCleaning {
    public static let defaultModel = "claude-haiku-4-5"

    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = AnthropicCleanupService.defaultModel,
        timeout: TimeInterval = 8.0,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.timeout = timeout
        self.session = session
    }

    public func clean(_ transcript: String, dictionary: TermDictionary) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard !apiKey.isEmpty else { throw CleanupError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": max(1024, trimmed.count / 2),
            "temperature": 0,
            "system": CleanupPrompt.systemInstruction(dictionaryHint: dictionary.cleanupHint()),
            "messages": [
                ["role": "user", "content": CleanupPrompt.userMessage(trimmed)]
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
            throw CleanupError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        if Self.wasTruncated(data) { throw CleanupError.truncated }

        guard let text = Self.extractText(from: data) else { throw CleanupError.emptyResponse }
        return text
    }

    /// True when the model stopped at `max_tokens` rather than finishing. The
    /// response is a 200 carrying a fragment, so nothing else distinguishes it.
    static func wasTruncated(_ data: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let reason = root["stop_reason"] as? String
        else { return false }
        return reason == "max_tokens"
    }

    /// Pulls the concatenated text blocks out of a Messages API response.
    static func extractText(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = root["content"] as? [[String: Any]]
        else { return nil }

        let text = blocks.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
