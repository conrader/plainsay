import FluidAudio
import Foundation

/// Optional pre-transcription filter: keeps only the audio attributed to one
/// enrolled speaker, so a second voice in the room never reaches the
/// transcription engine — or, for remote/Cloud sources, never leaves this
/// Mac at all.
///
/// Runs through FluidAudio's diarizer, the same library Parakeet uses. It is
/// a separate model download from either transcription engine, since voice
/// filtering works the same way regardless of which one is selected.
public actor VoiceFilterEngine {
    public typealias LoadState = SpeechModelLoadState

    private var diarizer: DiarizerManager?
    private var state: LoadState = .idle
    private let onStateChange: @Sendable (LoadState) -> Void

    public init(onStateChange: @escaping @Sendable (LoadState) -> Void = { _ in }) {
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
        if diarizer != nil { return }
        setState(.downloading(progress: 0))
        do {
            let models = try await DiarizerModels.downloadIfNeeded(
                progressHandler: { [weak self] progress in
                    Task { [weak self] in
                        await self?.reportDownloadProgress(progress)
                    }
                }
            )
            setState(.loading(progress: nil))
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizer = manager
            setState(.ready)
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    private func reportDownloadProgress(_ progress: DownloadProgress) {
        switch progress.phase {
        case .downloading, .listing:
            setState(.downloading(progress: LoadState.clampedProgress(progress.fractionCompleted)))
        case .compiling:
            setState(.loading(progress: nil))
        }
    }

    /// Extracts a voice embedding from an enrollment recording of one person
    /// speaking alone. A few seconds of natural speech is enough.
    public func enroll(samples: [Float]) throws -> [Float] {
        guard let diarizer else { throw VoiceFilterError.notReady }
        return try diarizer.extractSpeakerEmbedding(from: samples)
    }

    /// Keeps only the stretches of `samples` attributed to whichever speaker
    /// best matches `embedding`.
    ///
    /// Falls back to the untouched recording when diarization finds no
    /// segment within `threshold` of the enrolled voice at all — occasionally
    /// transcribing a stray second voice is a smaller loss than silently
    /// discarding the whole dictation because a match was uncertain.
    public func filtered(
        samples: [Float],
        matching embedding: [Float],
        threshold: Float = 0.6
    ) throws -> [Float] {
        guard let diarizer else { throw VoiceFilterError.notReady }
        let result = try diarizer.performCompleteDiarization(samples)

        let matches = result.segments
            .filter { SpeakerUtilities.cosineDistance($0.embedding, embedding) < threshold }
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        guard !matches.isEmpty else { return samples }

        var kept: [Float] = []
        kept.reserveCapacity(samples.count)
        for segment in matches {
            let start = max(0, Int(segment.startTimeSeconds * Float(whisperSampleRate)))
            let end = min(samples.count, Int(segment.endTimeSeconds * Float(whisperSampleRate)))
            guard start < end else { continue }
            kept.append(contentsOf: samples[start..<end])
        }
        return kept.isEmpty ? samples : kept
    }

    public func shutdown() {
        diarizer?.cleanup()
        diarizer = nil
        setState(.idle)
    }
}

public enum VoiceFilterError: LocalizedError {
    case notReady
    case sampleTooShort

    public var errorDescription: String? {
        switch self {
        case .notReady: "Voice filter model is not loaded yet."
        case .sampleTooShort: "That recording was too short to learn a voice from."
        }
    }
}

/// Records and enrolls a voice sample, independent of the main dictation
/// pipeline — enrollment happens from Settings or the Setup Assistant, never
/// while the hotkey is in use, so it owns its own recorder rather than
/// sharing `DictationCoordinator`'s.
@MainActor
@Observable
public final class VoiceEnrollment {
    private let recorder: any AudioRecording
    private let filterEngine: VoiceFilterEngine
    public private(set) var isRecording = false
    public private(set) var loadState: SpeechModelLoadState = .idle
    private var pollTask: Task<Void, Never>?

    /// Shorter than this isn't enough audio to extract a reliable embedding.
    public static let minimumSampleDuration: TimeInterval = 2.0

    public init(recorder: any AudioRecording = AudioRecorder()) {
        self.recorder = recorder
        self.filterEngine = VoiceFilterEngine()
    }

    public func prepare() async throws {
        startPolling()
        defer { pollTask?.cancel() }
        try await filterEngine.prepare()
        loadState = await filterEngine.loadState
    }

    /// `VoiceFilterEngine` reports state through a callback closure, which
    /// would need to capture `self` before this object finishes
    /// initializing. Polling its actor-isolated state sidesteps that rather
    /// than fighting Swift's initialization checker over it.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.loadState = await self.filterEngine.loadState
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    public func start() throws {
        try recorder.start()
        isRecording = true
    }

    /// Stops recording and returns a voice embedding, or nil if too little
    /// audio was captured to enroll from.
    public func stopAndExtractEmbedding() async throws -> [Float]? {
        isRecording = false
        let samples = recorder.stop()
        guard Double(samples.count) / whisperSampleRate >= Self.minimumSampleDuration else {
            return nil
        }
        return try await filterEngine.enroll(samples: samples)
    }

    public func cancel() {
        isRecording = false
        recorder.cancel()
        pollTask?.cancel()
    }
}
