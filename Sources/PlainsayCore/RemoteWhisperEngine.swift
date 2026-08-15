import Foundation

/// Where speech-to-text runs.
public enum TranscriptionSource: String, Codable, CaseIterable, Sendable, Identifiable {
    /// WhisperKit on this Mac. Free, private, no network.
    ///
    /// The default, and the product's actual claim. The two options below send
    /// audio off the machine, so neither may ever become the default.
    case onDevice
    /// Any OpenAI-compatible `/v1/audio/transcriptions` endpoint, your own key.
    case remote
    /// Plainsay Cloud: a subscription, with keys issued by the service.
    case cloud

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: "On this Mac (private, free)"
        case .remote: "Cloud API (your own key)"
        case .cloud: "Plainsay Cloud (subscription)"
        }
    }

    /// True when choosing this uploads recorded audio.
    public var leavesTheMachine: Bool { self != .onDevice }
}

/// Cloud speech-to-text providers, all speaking the OpenAI dialect.
public enum ASRProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case groq
    case deapi
    case openAI
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groq: "Groq"
        case .deapi: "deAPI"
        case .openAI: "OpenAI"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .groq: "https://api.groq.com/openai/v1"
        // deAPI's own v2 endpoint is asynchronous — it returns a request_id to
        // poll, which is unusable for dictation. Its OpenAI-compatible surface
        // is synchronous, so that is the one we speak to.
        case .deapi: "https://oai.deapi.ai/v1"
        case .openAI: "https://api.openai.com/v1"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .groq: "whisper-large-v3-turbo"
        // Native slugs, deliberately not OpenAI's naming.
        case .deapi: "WhisperLargeV3"
        case .openAI: "whisper-1"
        case .custom: ""
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .groq: ["whisper-large-v3-turbo", "whisper-large-v3"]
        case .deapi: ["WhisperLargeV3", "WhisperLargeV3Ct2"]
        case .openAI: ["whisper-1", "gpt-4o-mini-transcribe"]
        case .custom: []
        }
    }

    public var keychainAccount: String {
        switch self {
        case .groq: "groq-api-key"
        case .deapi: "deapi-api-key"
        case .openAI: "openai-api-key"
        case .custom: "custom-asr-api-key"
        }
    }

    public var signupURL: String? {
        switch self {
        case .groq: "https://console.groq.com/keys"
        case .deapi: "https://app.deapi.ai/settings/api-keys"
        case .openAI: "https://platform.openai.com/api-keys"
        case .custom: nil
        }
    }

    /// What to upload.
    ///
    /// deAPI rejects WAV outright, whatever MIME type it is sent under, and
    /// accepts m4a. The others are left on WAV because that is the path
    /// actually exercised against them — m4a would very likely work and upload
    /// five times less, but switching an unverified path on a guess trades a
    /// known-good default for an untested one.
    public var uploadFormat: AudioUploadFormat {
        switch self {
        case .deapi: .m4a
        case .groq, .openAI, .custom: .wav
        }
    }

    /// Rough cost per hour of audio, for the settings UI. Worth showing:
    /// the spread between providers is more than an order of magnitude.
    public var approximateCostPerHour: String? {
        switch self {
        case .groq: "~$0.04/hour of audio"
        case .deapi: "~$0.021/hour of audio · $5 free credit to start"
        case .openAI: "~$0.36/hour of audio"
        case .custom: nil
        }
    }
}

/// Speech-to-text via a hosted `/v1/audio/transcriptions` endpoint.
///
/// Sends audio off this machine, which is the whole trade: no 632MB model, no
/// Neural Engine warm-up, faster on older hardware — at the cost of privacy,
/// a network round trip, and a per-minute bill.
public actor RemoteWhisperEngine: TranscriptionEngine {
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let language: String?
    private let session: URLSession
    private let timeout: TimeInterval
    private let uploadFormat: AudioUploadFormat

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        language: String? = nil,
        uploadFormat: AudioUploadFormat = .wav,
        timeout: TimeInterval = 30,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.uploadFormat = uploadFormat
        self.timeout = timeout
        self.session = session
    }

    /// Nothing to load — the point of this engine is that there is no model.
    public func prepare() async throws {
        guard !apiKey.isEmpty else { throw TranscriptionError.failed("No API key for the transcription service") }
        guard !model.isEmpty else { throw TranscriptionError.failed("No transcription model selected") }
        guard URL(string: "\(baseURL)/audio/transcriptions") != nil else {
            throw TranscriptionError.failed("Invalid transcription endpoint: \(baseURL)")
        }
    }

    public func transcribe(samples: [Float], prompt: String?) async throws -> String {
        guard !samples.isEmpty else { return "" }
        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw TranscriptionError.failed("Invalid transcription endpoint: \(baseURL)")
        }

        let boundary = "plainsay-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields: [(String, String)] = [("model", model), ("response_format", "json")]
        if let language { fields.append(("language", language)) }
        // Same glossary trick as on-device: Whisper conditions on this text.
        if let prompt, !prompt.isEmpty { fields.append(("prompt", prompt)) }

        // AAC when the provider needs it, WAV when it does not — and WAV as the
        // fallback if encoding fails, because a bigger upload beats no dictation.
        var format = uploadFormat
        var audio: Data
        if format == .m4a, let encoded = AACEncoder.encode(samples: samples) {
            audio = encoded
        } else {
            if format == .m4a { Log.audio.error("AAC encoding failed — falling back to WAV upload") }
            format = .wav
            audio = WAVEncoder.encode(samples: samples)
        }

        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: fields,
            audio: audio,
            filename: format.filename,
            contentType: format.mimeType
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriptionError.failed("Transcription service timed out")
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.failed("No response from the transcription service")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.failed("HTTP \(http.statusCode): \(body.prefix(200))")
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = root["text"] as? String
        else {
            throw TranscriptionError.failed("Unexpected response from the transcription service")
        }

        return normalizeTranscript(text)
    }

    static func multipartBody(
        boundary: String,
        fields: [(String, String)],
        audio: Data,
        filename: String = "audio.wav",
        contentType: String = "audio/wav"
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")

        return body
    }
}

/// Minimal WAV writer.
///
/// The pipeline carries 16kHz mono Float32; transcription endpoints want a
/// container. 16-bit PCM is universally accepted and halves the upload versus
/// sending floats, with no audible cost at this sample rate.
public enum WAVEncoder {
    public static func encode(samples: [Float], sampleRate: Int = Int(whisperSampleRate)) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * bitsPerSample / 8

        var data = Data(capacity: 44 + dataSize)
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(UInt32(36 + dataSize))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                     // PCM header size
        u16(1)                      // PCM, uncompressed
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bitsPerSample))
        ascii("data")
        u32(UInt32(dataSize))

        for sample in samples {
            // Clamp before scaling: values slightly outside -1...1 would wrap
            // around and turn a loud passage into noise.
            let clamped = max(-1, min(1, sample))
            u16(UInt16(bitPattern: Int16(clamped * 32767)))
        }

        return data
    }
}
