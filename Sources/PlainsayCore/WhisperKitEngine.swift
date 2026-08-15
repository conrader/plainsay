import Foundation
import WhisperKit

/// On-device Whisper via WhisperKit (CoreML, Apple Neural Engine + GPU).
public actor WhisperKitEngine: TranscriptionEngine {
    public typealias LoadState = SpeechModelLoadState

    private var kit: WhisperKit?
    private let model: OnDeviceModel
    private let language: String?
    private var state: LoadState = .idle
    private let onStateChange: @Sendable (LoadState) -> Void

    /// - Parameters:
    ///   - language: BCP-47-ish Whisper code (`"en"`), or nil to auto-detect.
    ///   - onStateChange: progress reporting for the menu bar and settings UI.
    public init(
        model: OnDeviceModel = .largeV3Turbo,
        language: String? = nil,
        onStateChange: @escaping @Sendable (LoadState) -> Void = { _ in }
    ) {
        self.model = model
        self.language = language
        self.onStateChange = onStateChange
    }

    public var loadState: LoadState { state }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private func setState(_ new: LoadState) {
        state = new
        onStateChange(new)
    }

    public func prepare() async throws {
        if kit != nil { return }
        try Task.checkCancellation()

        guard let modelID = model.whisperKitModelID else {
            let message = "\(model.displayName) is not a WhisperKit model."
            setState(.failed(message))
            throw TranscriptionError.failed(message)
        }

        setState(.downloading(progress: 0))
        do {
            let config = WhisperKitConfig(
                model: modelID,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            setState(.loading)
            let loadedKit = try await WhisperKit(config)
            try Task.checkCancellation()
            kit = loadedKit
            setState(.ready)
        } catch is CancellationError {
            setState(.idle)
            throw CancellationError()
        } catch {
            setState(.failed(error.localizedDescription))
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    public func shutdown() async {
        kit = nil
        setState(.idle)
    }

    /// Whisper's window. Audio below this fits in a single pass, so splitting
    /// it can only lose material.
    private static let windowSeconds: Double = 30

    public func transcribe(samples: [Float], prompt: String?) async throws -> String {
        let text = try await run(samples: samples, prompt: prompt, relaxed: false)
        guard text.isEmpty else { return text }

        // An empty result on audio that clearly contained speech is a decoder
        // suppression, not silence. Retrying with the silence heuristics turned
        // off costs a second in the rare failure case and saves the dictation.
        guard Self.hasSignal(samples) else { return text }
        Log.model.info("empty transcript despite audible input — retrying with silence detection off")
        return try await run(samples: samples, prompt: prompt, relaxed: true)
    }

    /// True when the audio is loud enough that a human would hear speech.
    static func hasSignal(_ samples: [Float], threshold: Float = 0.02) -> Bool {
        var peak: Float = 0
        for sample in samples where abs(sample) > peak { peak = abs(sample) }
        return peak > threshold
    }

    private func run(samples: [Float], prompt: String?, relaxed: Bool) async throws -> String {
        guard let kit else { throw TranscriptionError.modelNotLoaded }

        // VAD chunking exists to split audio longer than the model's window.
        // Applied to a short dictation it has nothing to divide and can
        // classify the whole clip as non-speech, yielding no chunks at all.
        let needsChunking = Double(samples.count) / whisperSampleRate > Self.windowSeconds

        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: model.isEnglishOnly ? "en" : language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: model.isEnglishOnly ? false : (language == nil),
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Quiet, close-mic dictation sits near these thresholds, and both
            // must fire together for Whisper to declare silence. Loosening them
            // trades the odd hallucination on true silence — which the empty
            // check catches anyway — for not dropping a real sentence.
            compressionRatioThreshold: relaxed ? nil : 2.4,
            logProbThreshold: relaxed ? nil : -1.0,
            noSpeechThreshold: relaxed ? nil : 0.9,
            chunkingStrategy: needsChunking ? .vad : nil
        )

        if let prompt, let tokenizer = kit.tokenizer {
            // Special tokens in a prompt confuse the decoder; keep text only.
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
            }
        }

        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let joined = results.map(\.text).joined(separator: " ")
            return normalizeTranscript(joined)
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }
}
