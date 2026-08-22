import Foundation

/// Transcription for the Cloud plan, proxied through Plainsay's own server.
///
/// Deliberately not a direct call to deAPI. The client never sees a deAPI
/// key at all — it authenticates with its own session token, the server
/// calls deAPI with a key that never leaves the box, and records usage as a
/// straightforward side effect of doing that work. That is strictly more
/// reliable than a client-side usage report: there is nothing here to skip,
/// drop, or lie about, and nothing in the app "reports" anything — the
/// server simply knows what it did.
///
/// If deAPI ever offers per-subscriber keys the way OpenRouter already does,
/// this can go back to a direct call with its own cap, same as cleanup. Until
/// then, proxying is the only way to meter it.
public actor CloudTranscriptionEngine: TranscriptionEngine {
    private struct UploadMetadata: Encodable {
        let durationSeconds: Double
        let language: String?
        let prompt: String?
    }

    private let baseURL: String
    private let sessionToken: String
    private let language: String?
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: String,
        sessionToken: String,
        language: String? = nil,
        timeout: TimeInterval = 30,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.sessionToken = sessionToken
        self.language = language
        self.timeout = timeout
        self.session = session
    }

    /// Nothing to load — the point of this engine is that there is no model.
    public func prepare() async throws {}

    public func transcribe(samples: [Float], prompt: String?) async throws -> String {
        guard !samples.isEmpty else { return "" }

        // The server records this as the dictation's cost, so it has to
        // match what was actually recorded, not be derived after re-encoding.
        let durationSeconds = Double(samples.count) / whisperSampleRate

        guard let audio = AACEncoder.encode(samples: samples) else {
            throw TranscriptionError.failed(
                Localization.coreString("engine.cloud.encodeFailed", fallback: "Could not encode audio for upload")
            )
        }

        guard let url = URL(string: "\(baseURL)/v1/transcribe") else {
            throw TranscriptionError.failed(
                Localization.coreFormat(
                    "engine.invalidEndpoint", fallback: "Invalid transcription endpoint: %@", baseURL
                )
            )
        }

        // Vocabulary terms and language hints can be sensitive. Keep them out
        // of the request URL, which reverse proxies commonly include in access
        // logs. The server decodes this Base64URL JSON header and redacts the
        // header itself from application logs.
        let metadata = UploadMetadata(
            durationSeconds: durationSeconds,
            language: language?.isEmpty == false ? language : nil,
            prompt: prompt?.isEmpty == false ? prompt : nil
        )
        let metadataData = try JSONEncoder().encode(metadata)
        let encodedMetadata = metadataData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AudioUploadFormat.m4a.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(encodedMetadata, forHTTPHeaderField: "X-Plainsay-Metadata")
        request.httpBody = audio

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriptionError.failed(
                Localization.coreString("engine.cloud.timedOut", fallback: "Plainsay Cloud timed out")
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.failed(
                Localization.coreString("engine.cloud.noResponse", fallback: "No response from Plainsay Cloud")
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 402 {
                throw TranscriptionError.failed(
                    Localization.coreString(
                        "engine.cloud.subscriptionInactive", fallback: "Plainsay Cloud subscription is not active"
                    )
                )
            }
            if http.statusCode == 429 {
                throw TranscriptionError.failed(
                    Localization.coreString(
                        "engine.cloud.limitReached",
                        fallback: "Plainsay Cloud rolling 30-day limit reached"
                    )
                )
            }
            throw TranscriptionError.failed(
                Localization.coreFormat(
                    "engine.cloud.httpError", fallback: "Plainsay Cloud HTTP %d: %@", http.statusCode,
                    String(body.prefix(200))
                )
            )
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = root["text"] as? String
        else {
            throw TranscriptionError.failed(
                Localization.coreString(
                    "engine.cloud.unexpectedResponse", fallback: "Unexpected response from Plainsay Cloud"
                )
            )
        }
        return normalizeTranscript(text)
    }
}
