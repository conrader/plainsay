import Foundation
// WhisperKit 1.1 predates Swift 6 sendability annotations. The entire
// instance is owned and used by this actor, so importing its declarations as
// pre-concurrency accurately describes the isolation boundary.
@preconcurrency import WhisperKit

/// On-device Whisper via WhisperKit (CoreML, Apple Neural Engine + GPU).
public actor WhisperKitEngine: TranscriptionEngine {
    public typealias LoadState = SpeechModelLoadState

    private var kit: WhisperKit?
    private let model: OnDeviceModel
    private let spokenLanguages: [String]
    private var state: LoadState = .idle
    private let onStateChange: @Sendable (LoadState) -> Void
    private var activeLoadID: UUID?
    private var isDownloading = false

    /// - Parameters:
    ///   - spokenLanguages: Whisper codes (`["pl", "en"]`) the user actually
    ///     speaks, most-used first, or empty to auto-detect across every
    ///     language Whisper knows. Detection still runs first either way; a
    ///     non-empty list only triggers a forced retry when the detected
    ///     language falls outside it.
    ///   - onStateChange: progress reporting for the menu bar and settings UI.
    public init(
        model: OnDeviceModel = .largeV3Turbo,
        spokenLanguages: [String] = [],
        onStateChange: @escaping @Sendable (LoadState) -> Void = { _ in }
    ) {
        self.model = model
        self.spokenLanguages = spokenLanguages
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

    private func reportDownloadProgress(_ progress: Double, loadID: UUID) {
        guard activeLoadID == loadID, isDownloading else { return }
        setState(.downloading(progress: LoadState.clampedProgress(progress)))
    }

    public func prepare() async throws {
        if kit != nil { return }
        try Task.checkCancellation()

        guard let modelID = model.whisperKitModelID else {
            let message = Localization.coreFormat(
                "engine.notWhisperKitModel", fallback: "%@ is not a WhisperKit model.", model.displayName
            )
            setState(.failed(message))
            throw TranscriptionError.failed(message)
        }

        let loadID = UUID()
        activeLoadID = loadID
        isDownloading = true
        setState(.downloading(progress: 0))
        do {
            let modelFolder = try await WhisperKit.download(
                variant: modelID,
                progressCallback: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { [weak self] in
                        await self?.reportDownloadProgress(fraction, loadID: loadID)
                    }
                }
            )
            try Task.checkCancellation()
            guard activeLoadID == loadID else { throw CancellationError() }

            isDownloading = false
            setState(.loading(progress: nil))

            // Between the download and the load, because after the load is too
            // late: `WhisperKit(config)` compiles and runs this code. WhisperKit
            // itself never hashes a file it just fetched (#27).
            try ModelIntegrity.verifyOrDiscard(model: modelID, in: modelFolder)

            let config = WhisperKitConfig(
                model: modelID,
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            let loadedKit = try await WhisperKit(config)
            try Task.checkCancellation()
            guard activeLoadID == loadID else { throw CancellationError() }
            kit = loadedKit
            activeLoadID = nil
            setState(.ready)
        } catch is CancellationError {
            if activeLoadID == loadID {
                activeLoadID = nil
                isDownloading = false
                setState(.idle)
            }
            throw CancellationError()
        } catch {
            if activeLoadID == loadID {
                activeLoadID = nil
                isDownloading = false
                setState(.failed(error.localizedDescription))
            }
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    public func shutdown() async {
        activeLoadID = nil
        isDownloading = false
        kit = nil
        setState(.idle)
    }

    /// Whisper's window. Audio below this fits in a single pass, so splitting
    /// it can only lose material.
    private static let windowSeconds: Double = 30

    public func transcribe(samples: [Float], prompt: String?) async throws -> String {
        var result = try await run(samples: samples, prompt: prompt, relaxed: false, forceLanguage: nil)

        if result.text.isEmpty, Self.hasSignal(samples) {
            // An empty result on audio that clearly contained speech is a
            // decoder suppression, not silence. Retrying with the silence
            // heuristics off costs a second in the rare failure case and
            // saves the dictation.
            Log.model.info("empty transcript despite audible input — retrying with silence detection off")
            result = try await run(samples: samples, prompt: prompt, relaxed: true, forceLanguage: nil)
        }

        if !result.text.isEmpty,
           let forced = languageToForce(detected: result.language, text: result.text) {
            // Whisper auto-detection occasionally lands on a language the
            // user never speaks (a few misheard syllables read as Russian,
            // say). Retrying forced to a language they actually use is worth
            // the extra pass — silently keeping a wrong-language transcript
            // is worse.
            Log.model.info("detected \(result.language), outside spoken-languages list — retrying forced to \(forced)")
            let retried = try await run(samples: samples, prompt: prompt, relaxed: false, forceLanguage: forced)
            if !retried.text.isEmpty { return retried.text }
        }

        return result.text
    }

    /// The language to force-retry with, or nil if the result is acceptable.
    ///
    /// Two independent signals, because they fail in different ways. Whisper's
    /// own `detected` language catches a clip read wholesale as Russian. But it
    /// can also report the right language and still write the wrong one — a
    /// Polish word coming back as Czech, both of them Latin-script Slavic — and
    /// then the only evidence is in the text itself.
    private func languageToForce(detected: String, text: String) -> String? {
        guard let primary = spokenLanguages.first else { return nil }
        let allowed = Set(spokenLanguages.map(SupportedLanguage.primaryCode))
        if !allowed.contains(SupportedLanguage.primaryCode(detected)) { return primary }
        if LanguageEvidence.isOutsideSpokenLanguages(text, spokenLanguages: spokenLanguages) {
            return primary
        }
        return nil
    }

    /// True when the audio is loud enough that a human would hear speech.
    static func hasSignal(_ samples: [Float], threshold: Float = 0.02) -> Bool {
        var peak: Float = 0
        for sample in samples where abs(sample) > peak { peak = abs(sample) }
        return peak > threshold
    }

    private func run(
        samples: [Float],
        prompt: String?,
        relaxed: Bool,
        forceLanguage: String?
    ) async throws -> (text: String, language: String) {
        guard let kit else { throw TranscriptionError.modelNotLoaded }

        // VAD chunking exists to split audio longer than the model's window.
        // Applied to a short dictation it has nothing to divide and can
        // classify the whole clip as non-speech, yielding no chunks at all.
        let needsChunking = Double(samples.count) / whisperSampleRate > Self.windowSeconds

        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: model.isEnglishOnly ? "en" : forceLanguage,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: model.isEnglishOnly ? false : (forceLanguage == nil),
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
            let detected = forceLanguage ?? results.first?.language ?? "en"
            return (normalizeTranscript(joined), detected)
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }
}
