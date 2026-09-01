import Foundation

/// Polishing for the Cloud plan and for anyone who picks Plainsay as their
/// Polishing provider, proxied through Plainsay's own server.
///
/// Deliberately not a direct call to Gemini or a per-subscriber minted key.
/// The client never sees a Gemini key at all — it authenticates with its own
/// session token, the same one `CloudTranscriptionEngine` uses, and the
/// server calls Gemini with a key that never leaves the box.
public struct CloudCleanupService: TextCleaning {
    private let baseURL: String
    private let sessionToken: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: String,
        sessionToken: String,
        timeout: TimeInterval = 15,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.sessionToken = sessionToken
        self.timeout = timeout
        self.session = session
    }

    public func clean(_ transcript: String, dictionary: TermDictionary, style: CleanupStyle) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard let url = URL(string: "\(baseURL)/v1/cleanup") else {
            throw CleanupError.invalidEndpoint(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["transcript": trimmed]
        if let terms = dictionary.cleanupHint() { body["terms"] = terms }

        // Structured fields, never prompt text. The server composes the
        // instruction from these; a client that could supply wording could
        // make a key Plainsay pays for do anything at all.
        //
        // These were missing, and it was invisible: email layout and
        // translation are both gated on holding a Cloud subscription, and this
        // is the route a subscriber uses — so the only people entitled to
        // those features were the only people for whom they did nothing. The
        // field names must match `/v1/cleanup` in plainsay-server, and there
        // is a test on each side asserting these exact strings.
        if style.layout == .email { body["layout"] = "email" }
        if let target = style.translateTo { body["translateTo"] = target }
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

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = root["text"] as? String
        else { throw CleanupError.emptyResponse }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { throw CleanupError.emptyResponse }
        return trimmedText
    }
}
