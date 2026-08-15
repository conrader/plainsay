import Foundation
import WhisperKit

/// On-device Whisper via WhisperKit (CoreML, Apple Neural Engine + GPU).
public actor WhisperKitEngine: TranscriptionEngine {
    public enum LoadState: Sendable, Equatable {
        case idle
        case downloading(progress: Double)
        case loading
        case ready
        case failed(String)
    }

    private var kit: WhisperKit?
    private let model: WhisperModel
    private let language: String?
    private var state: LoadState = .idle
    private let onStateChange: @Sendable (LoadState) -> Void

    /// - Parameters:
    ///   - language: BCP-47-ish Whisper code (`"en"`), or nil to auto-detect.
    ///   - onStateChange: progress reporting for the menu bar and settings UI.
    public init(
        model: WhisperModel = .largeV3Turbo,
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

        setState(.downloading(progress: 0))
        do {
            let config = WhisperKitConfig(
                model: model.rawValue,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            setState(.loading)
            kit = try await WhisperKit(config)
            setState(.ready)
        } catch {
            setState(.failed(error.localizedDescription))
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    public func transcribe(samples: [Float], prompt: String?) async throws -> String {
        guard let kit else { throw TranscriptionError.modelNotLoaded }

        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: model.isEnglishOnly ? "en" : language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: model.isEnglishOnly ? false : (language == nil),
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // VAD chunking keeps long dictations from being cut at fixed
            // 30s window boundaries mid-word.
            chunkingStrategy: .vad
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
