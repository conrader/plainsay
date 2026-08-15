import FluidAudio
import Foundation

/// On-device NVIDIA Parakeet TDT 0.6B v3 through FluidAudio and Core ML.
///
/// Plainsay already captures exactly the input this model expects: mono
/// Float32 PCM at 16 kHz. The manager stays resident between dictations, while
/// decoder state is deliberately fresh for every utterance so one dictation
/// cannot leak linguistic context into the next.
public actor ParakeetEngine: TranscriptionEngine {
    public typealias LoadState = SpeechModelLoadState

    private var manager: AsrManager?
    private let language: String?
    private var state: LoadState = .idle
    private let onStateChange: @Sendable (LoadState) -> Void
    private var activeTranscriptions = 0
    private var shutdownRequested = false

    public init(
        language: String? = nil,
        onStateChange: @escaping @Sendable (LoadState) -> Void = { _ in }
    ) {
        self.language = language
        self.onStateChange = onStateChange
    }

    public var loadState: LoadState { state }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private func setState(_ newState: LoadState) {
        state = newState
        onStateChange(newState)
    }

    public func prepare() async throws {
        if manager != nil { return }
        guard !shutdownRequested else { throw CancellationError() }
        try Task.checkCancellation()

        #if !arch(arm64)
        let message = "NVIDIA Parakeet requires a Mac with Apple silicon."
        setState(.failed(message))
        throw TranscriptionError.failed(message)
        #else
        setState(.downloading(progress: 0))
        let reportProgress = onStateChange

        do {
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { progress in
                    switch progress.phase {
                    case .compiling:
                        reportProgress(.loading)
                    case .listing, .downloading:
                        reportProgress(.downloading(progress: progress.fractionCompleted))
                    }
                }
            )
            try Task.checkCancellation()

            setState(.loading)
            // FluidAudio recommends disabling mel-context carry-over for v3
            // multilingual recordings longer than a single model window. It
            // prevents later Polish chunks drifting toward English.
            let manager = AsrManager(config: ASRConfig(melChunkContext: false))
            try await manager.loadModels(models)

            // Model selection may have changed while FluidAudio was compiling
            // on the Neural Engine. Do not resurrect a superseded engine.
            guard !Task.isCancelled, !shutdownRequested else {
                await manager.cleanup()
                setState(.idle)
                throw CancellationError()
            }
            self.manager = manager
            setState(.ready)
        } catch is CancellationError {
            setState(.idle)
            throw CancellationError()
        } catch {
            setState(.failed(error.localizedDescription))
            throw TranscriptionError.failed(error.localizedDescription)
        }
        #endif
    }

    public func transcribe(samples: [Float], prompt: String?) async throws -> String {
        guard !samples.isEmpty else { return "" }
        guard !shutdownRequested, let manager else {
            throw TranscriptionError.modelNotLoaded
        }

        activeTranscriptions += 1

        do {
            let decoderLayers = await manager.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: Self.languageHint(from: language)
            )

            // Parakeet has no prompt input. The same vocabulary still reaches
            // Plainsay's cleanup stage, which repairs uncommon spellings.
            _ = prompt
            let transcript = normalizeTranscript(result.text)
            await finishTranscription()
            return transcript
        } catch {
            await finishTranscription()
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    public func shutdown() async {
        shutdownRequested = true
        guard activeTranscriptions == 0 else { return }
        await releaseManager()
    }

    private func finishTranscription() async {
        activeTranscriptions -= 1
        if activeTranscriptions == 0, shutdownRequested {
            await releaseManager()
        }
    }

    private func releaseManager() async {
        // Clear the stored reference before awaiting so concurrent shutdown
        // calls cannot clean up the same FluidAudio manager twice.
        let manager = manager
        self.manager = nil
        if let manager {
            await manager.cleanup()
        }
        setState(.idle)
    }

    /// FluidAudio's hint filters writing scripts rather than choosing a model.
    /// Nil keeps automatic multilingual decoding, which is the right default
    /// for Polish/English code-switching.
    private static func languageHint(from code: String?) -> Language? {
        guard let primary = code?
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
        else { return nil }
        return Language(rawValue: String(primary))
    }
}
