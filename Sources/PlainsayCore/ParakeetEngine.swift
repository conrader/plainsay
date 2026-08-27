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
    /// Every language the speaker listed, not just the primary. The hint
    /// below can only carry one, but judging whether a transcript came out
    /// in a language they never speak needs the whole set — otherwise a
    /// Polish word from someone whose list starts with English reads as
    /// foreign when it is exactly what they said.
    private let spokenLanguages: [String]
    private var state: LoadState = .idle
    private let onStateChange: @Sendable (LoadState) -> Void
    private var activeTranscriptions = 0
    private var shutdownRequested = false
    private var activeLoadID: UUID?
    private var acceptsFluidProgress = false
    private var progressPresentation = ProgressPresentation()

    public init(
        language: String? = nil,
        spokenLanguages: [String] = [],
        onStateChange: @escaping @Sendable (LoadState) -> Void = { _ in }
    ) {
        self.language = language
        self.spokenLanguages = spokenLanguages.isEmpty ? [language].compactMap { $0 } : spokenLanguages
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

    /// `AsrModels.downloadAndLoad` performs several FluidAudio repo operations.
    /// Each operation restarts its own 0...1 fraction, so treating every event
    /// as whole-model progress makes the UI jump from Loading 100% back to
    /// Downloading 0%. The first operation downloads the complete repository;
    /// once compilation begins, keep a stable indeterminate preparation state
    /// and ignore the later per-component resets.
    struct ProgressPresentation: Sendable {
        private(set) var hasBegunLoading = false

        mutating func state(
            fractionCompleted: Double,
            isCompiling: Bool
        ) -> LoadState? {
            guard !hasBegunLoading else { return nil }
            if isCompiling {
                hasBegunLoading = true
                return .loading(progress: nil)
            }
            return .downloading(
                progress: LoadState.clampedProgress(fractionCompleted * 2)
            )
        }
    }

    private func receiveFluidProgress(
        fractionCompleted: Double,
        isCompiling: Bool,
        loadID: UUID
    ) {
        guard activeLoadID == loadID, acceptsFluidProgress else { return }
        guard let state = progressPresentation.state(
            fractionCompleted: fractionCompleted,
            isCompiling: isCompiling
        ) else { return }
        setState(state)
    }

    public func prepare() async throws {
        if manager != nil { return }
        guard !shutdownRequested else { throw CancellationError() }
        try Task.checkCancellation()

        #if !arch(arm64)
        let message = Localization.coreString(
            "engine.parakeetNeedsAppleSilicon", fallback: "NVIDIA Parakeet requires a Mac with Apple silicon."
        )
        setState(.failed(message))
        throw TranscriptionError.failed(message)
        #else
        let loadID = UUID()
        activeLoadID = loadID
        acceptsFluidProgress = true
        progressPresentation = ProgressPresentation()
        setState(.downloading(progress: 0))

        do {
            // `downloadAndLoad` is deliberately not used: it loads the model
            // in the same call that fetches it, leaving nowhere to check what
            // arrived. FluidAudio never hashes downloaded files at all — it
            // uses ETags only to resume interrupted transfers (#27).
            let modelDirectory = try await AsrModels.download(
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { [weak self] progress in
                    let isCompiling: Bool
                    switch progress.phase {
                    case .compiling:
                        isCompiling = true
                    case .listing, .downloading:
                        isCompiling = false
                    }
                    let fraction = progress.fractionCompleted
                    Task { [weak self] in
                        await self?.receiveFluidProgress(
                            fractionCompleted: fraction,
                            isCompiling: isCompiling,
                            loadID: loadID
                        )
                    }
                }
            )
            try Task.checkCancellation()
            guard activeLoadID == loadID else { throw CancellationError() }

            // `AsrModels.download` does not return the directory it wrote to.
            // It writes into a *sibling* of the path it hands back — the repo
            // folder beside it — so verifying the returned URL checks an empty
            // directory and finds nothing. That mistake shipped: it made every
            // Parakeet load fail, and because a failure also deletes, the app
            // re-downloaded the model on every launch, for ever.
            let contentDirectory = Self.resolveModelDirectory(from: modelDirectory)
            try ModelIntegrity.verifyOrDiscard(
                model: OnDeviceModel.parakeetTDT06BV3.rawValue,
                in: contentDirectory
            )

            let models = try await AsrModels.load(
                from: modelDirectory,
                version: .v3,
                encoderPrecision: .int8
            )
            try Task.checkCancellation()
            guard activeLoadID == loadID else { throw CancellationError() }

            // Progress from the download is no longer relevant. In particular,
            // a delayed callback must not replace `.ready` later.
            acceptsFluidProgress = false
            setState(.loading(progress: nil))
            // FluidAudio recommends disabling mel-context carry-over for v3
            // multilingual recordings longer than a single model window. It
            // prevents later Polish chunks drifting toward English.
            let manager = AsrManager(config: ASRConfig(melChunkContext: false))
            try await manager.loadModels(models)

            // Model selection may have changed while FluidAudio was compiling
            // on the Neural Engine. Do not resurrect a superseded engine.
            guard !Task.isCancelled, !shutdownRequested else {
                await manager.cleanup()
                if activeLoadID == loadID {
                    activeLoadID = nil
                    setState(.idle)
                }
                throw CancellationError()
            }
            self.manager = manager
            activeLoadID = nil
            setState(.ready)
        } catch is CancellationError {
            if activeLoadID == loadID {
                activeLoadID = nil
                acceptsFluidProgress = false
                setState(.idle)
            }
            throw CancellationError()
        } catch {
            if activeLoadID == loadID {
                activeLoadID = nil
                acceptsFluidProgress = false
                setState(.failed(error.localizedDescription))
            }
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

            // Parakeet cannot be forced to a language and reports no detected
            // one, so unlike Whisper there is no retry to make here. Logging it
            // is what turns "it sometimes comes out Czech" from an anecdote
            // into something that can be counted — and the language hint is no
            // help: FluidAudio's filter partitions by Unicode script only, so
            // for two Latin-script languages it rules out nothing.
            if LanguageEvidence.isOutsideSpokenLanguages(transcript, spokenLanguages: spokenLanguages) {
                let evidence = LanguageEvidence.languages(in: transcript).sorted().joined(separator: ",")
                let spoken = spokenLanguages.joined(separator: ",")
                Log.model.error(
                    "transcript shows letters exclusive to \(evidence, privacy: .public), outside spoken languages \(spoken, privacy: .public)"
                )
            }

            await finishTranscription()
            return transcript
        } catch {
            await finishTranscription()
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }

    public func shutdown() async {
        shutdownRequested = true
        activeLoadID = nil
        acceptsFluidProgress = false
        progressPresentation = ProgressPresentation()
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
    /// The directory that actually holds the model files.
    ///
    /// Located by looking for the vocabulary, which every Parakeet layout has:
    /// first where the download said, then among its siblings. Searching for a
    /// known file rather than reconstructing FluidAudio's private path scheme
    /// means a future change to that scheme degrades to "not found" — which is
    /// now merely unverified — instead of silently checking somewhere empty.
    static func resolveModelDirectory(from downloaded: URL) -> URL {
        let vocabulary = "parakeet_vocab.json"
        let manager = FileManager.default

        if manager.fileExists(atPath: downloaded.appending(path: vocabulary).path) {
            return downloaded
        }
        let parent = downloaded.deletingLastPathComponent()
        let siblings = (try? manager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for sibling in siblings
        where manager.fileExists(atPath: sibling.appending(path: vocabulary).path) {
            return sibling
        }
        return downloaded
    }

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
