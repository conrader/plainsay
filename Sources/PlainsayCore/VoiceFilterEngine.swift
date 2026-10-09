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

    /// Removes the stretches of `samples` attributed to a speaker other than
    /// the one matching `embedding`.
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
        try filter(samples: samples, matching: embedding, threshold: threshold).samples
    }

    /// `filtered`, plus which stretches were removed, for the log.
    public func filter(
        samples: [Float],
        matching embedding: [Float],
        threshold: Float = 0.6
    ) throws -> VoiceFilterOutcome {
        guard let diarizer else { throw VoiceFilterError.notReady }
        let result = try diarizer.performCompleteDiarization(samples)
        return Self.filtering(
            samples, segments: result.segments, matching: embedding, threshold: threshold
        )
    }

    /// FluidAudio's `DiarizerConfig.chunkDuration` default, which
    /// `DiarizerManager()` uses.
    static let diarizerChunkSeconds: Double = 10
    /// Less speech than this from an unmatched speaker is kept: too little to
    /// tell a second person from the user's own voice gone astray.
    static let minimumOtherSpeakerSeconds: Double = 3

    static func removingOtherSpeakers(
        from samples: [Float],
        segments: [TimedSpeakerSegment],
        matching embedding: [Float],
        threshold: Float
    ) -> [Float] {
        filtering(samples, segments: segments, matching: embedding, threshold: threshold).samples
    }

    /// The decision behind `filter`, apart from the diarizer so it can be
    /// tested without a model.
    ///
    /// The diarizer works in 10 s windows and gives each window's speaker its
    /// own embedding, so a recording's last window — often a few seconds of
    /// speech padded out with silence — carries the weakest one. Matching each
    /// segment's embedding against the enrollment dropped that whole window
    /// whenever it missed the threshold — the likeliest reading of a 37 s
    /// dictation that came back cut off mid-sentence (2026-10-08), since its
    /// last 7 s were exactly such a window. So a speaker is matched by the identity
    /// the diarizer gave it across the recording: one confident match vouches
    /// for every segment carrying that speaker's id.
    ///
    /// And only audio positively attributed to someone else is removed.
    /// Anything the diarizer left unattributed — speech under its 1 s minimum,
    /// a window whose embedding failed validation, the pauses between
    /// segments — stays, because a second voice it could not even pick out is
    /// a smaller loss than the user's own words.
    ///
    /// Nor is every new speaker id evidence of a second person. The diarizer
    /// mints one for any 1 s of speech that misses its existing speakers, and
    /// a closing phrase in the padded last window does exactly that: a 43.54 s
    /// dictation (2026-10-08 17:43) kept 42.21 s and lost its last words. So a
    /// speaker is removed only when there is real evidence it is someone else
    /// — at least `minimumOtherSpeakerSeconds` of speech, and not first heard
    /// in the recording's padded last window.
    static func filtering(
        _ samples: [Float],
        segments: [TimedSpeakerSegment],
        matching embedding: [Float],
        threshold: Float
    ) -> VoiceFilterOutcome {
        let untouched = VoiceFilterOutcome(samples: samples, removed: [])
        let enrolledIDs = Set(
            segments
                .filter { SpeakerUtilities.cosineDistance($0.embedding, embedding) < threshold }
                .map(\.speakerId)
        )
        guard !enrolledIDs.isEmpty else { return untouched }

        func range(of segment: TimedSpeakerSegment) -> Range<Int>? {
            let start = max(0, Int(segment.startTimeSeconds * Float(whisperSampleRate)))
            let end = min(samples.count, Int(segment.endTimeSeconds * Float(whisperSampleRate)))
            return start < end ? start..<end : nil
        }

        let otherSegments = segments.filter { !enrolledIDs.contains($0.speakerId) }
        // The diarizer's last window starts at the last multiple of its
        // chunk; when the recording ends inside it, the rest is zero padding.
        let chunk = Int(diarizerChunkSeconds * whisperSampleRate)
        let lastWindowStart = samples.isEmpty ? 0 : (samples.count - 1) / chunk * chunk
        let lastWindowIsPadded = samples.count % chunk != 0
        let removableIDs = Set(otherSegments.map(\.speakerId)).filter { id in
            let ranges = otherSegments.filter { $0.speakerId == id }.compactMap(range(of:))
            let seconds = Double(ranges.reduce(0) { $0 + $1.count }) / whisperSampleRate
            guard seconds >= minimumOtherSpeakerSeconds else { return false }
            let bornInPaddedTail = lastWindowIsPadded && ranges.allSatisfy { $0.lowerBound >= lastWindowStart }
            return !bornInPaddedTail
        }

        var keep = [Bool](repeating: true, count: samples.count)
        for segment in otherSegments where removableIDs.contains(segment.speakerId) {
            guard let range = range(of: segment) else { continue }
            keep.replaceSubrange(range, with: repeatElement(false, count: range.count))
        }
        // Overlapping speech still has the user in it.
        for segment in segments where enrolledIDs.contains(segment.speakerId) {
            guard let range = range(of: segment) else { continue }
            keep.replaceSubrange(range, with: repeatElement(true, count: range.count))
        }

        var kept: [Float] = []
        kept.reserveCapacity(samples.count)
        var removed: [Range<Double>] = []
        var removedStart: Int?
        for (index, sample) in samples.enumerated() {
            if keep[index] {
                kept.append(sample)
                if let start = removedStart {
                    removed.append(Double(start) / whisperSampleRate..<Double(index) / whisperSampleRate)
                    removedStart = nil
                }
            } else if removedStart == nil {
                removedStart = index
            }
        }
        if let start = removedStart {
            removed.append(Double(start) / whisperSampleRate..<Double(samples.count) / whisperSampleRate)
        }
        return kept.isEmpty ? untouched : VoiceFilterOutcome(samples: kept, removed: removed)
    }

    public func shutdown() {
        diarizer?.cleanup()
        diarizer = nil
        setState(.idle)
    }
}

/// What the voice filter kept, and which stretches of the recording it
/// removed — the ranges are what make a lost ending diagnosable from the log.
public struct VoiceFilterOutcome: Sendable {
    public let samples: [Float]
    /// Removed stretches in seconds from the start of the recording, in order.
    public let removed: [Range<Double>]

    /// "20.00-25.00s, 41.00-43.54s", or "none".
    public static func describe(_ ranges: [Range<Double>]) -> String {
        guard !ranges.isEmpty else { return "none" }
        return ranges
            .map { String(format: "%.2f-%.2fs", $0.lowerBound, $0.upperBound) }
            .joined(separator: ", ")
    }
}

/// Hidden diagnostic: with `defaults write <bundle id> PlainsayDebugSaveAudio
/// -bool YES`, the last dictation's captured and filtered audio are written to
/// ~/Library/Application Support/Plainsay/debug/, overwriting the previous
/// pair, so a lost ending can be listened to rather than guessed at.
enum VoiceFilterDebugAudio {
    static let defaultsKey = "PlainsayDebugSaveAudio"

    static func saveIfEnabled(
        captured: [Float], filtered: [Float], defaults: UserDefaults = .standard
    ) {
        guard defaults.bool(forKey: defaultsKey) else { return }
        Task.detached(priority: .utility) {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Plainsay/debug", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try WAVEncoder.encode(samples: captured)
                    .write(to: directory.appendingPathComponent("last-captured.wav"), options: .atomic)
                try WAVEncoder.encode(samples: filtered)
                    .write(to: directory.appendingPathComponent("last-filtered.wav"), options: .atomic)
            } catch {
                Log.pipeline.error("debug audio not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

public enum VoiceFilterError: LocalizedError {
    case notReady
    case sampleTooShort

    public var errorDescription: String? {
        switch self {
        case .notReady:
            Localization.coreString("voiceFilter.notReady", fallback: "Voice filter model is not loaded yet.")
        case .sampleTooShort:
            Localization.coreString(
                "voiceFilter.sampleTooShort", fallback: "That recording was too short to learn a voice from."
            )
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
    /// Phase markers for the voice-filter download, so the same watchdog that
    /// covers the transcription model can say how long this one has been
    /// going and whether it has stopped moving. Without it the only thing on
    /// screen is an indeterminate bar, which cannot be told apart from a hang.
    public private(set) var loadTiming: SpeechModelLoadTiming?
    private var pollTask: Task<Void, Never>?
    private let now: @MainActor @Sendable () -> Date
    /// Injected so tests can exercise a refusal without a real TCC prompt —
    /// a test run that raises the system microphone dialog is a test run
    /// nobody can leave unattended.
    private let requestMicrophone: @MainActor @Sendable () async -> Bool

    /// Shorter than this isn't enough audio to extract a reliable embedding.
    public static let minimumSampleDuration: TimeInterval = 2.0

    /// True while the voice-filter model is downloading or being prepared, so
    /// surfaces outside Settings — the menu bar above all — can say that
    /// something is in flight instead of looking inert.
    public var isPreparingModel: Bool {
        switch loadState {
        case .downloading, .loading: true
        case .idle, .ready, .failed: false
        }
    }

    public init(
        recorder: any AudioRecording = AudioRecorder(),
        now: @escaping @MainActor @Sendable () -> Date = { Date() },
        requestMicrophone: @escaping @MainActor @Sendable () async -> Bool = {
            await AudioRecorder.requestMicrophoneAccess()
        }
    ) {
        self.recorder = recorder
        self.filterEngine = VoiceFilterEngine()
        self.now = now
        self.requestMicrophone = requestMicrophone
    }

    public func prepare() async throws {
        startPolling()
        do {
            try await filterEngine.prepare()
        } catch {
            // The engine records `.failed` before it throws, but the poll may
            // not have read it yet. Publish the terminal state here, or the
            // last non-terminal sample is what stays on screen: a progress bar
            // that animates forever over a load that already gave up.
            await syncLoadState()
            throw error
        }
        await syncLoadState()
    }

    /// `VoiceFilterEngine` reports state through a callback closure, which
    /// would need to capture `self` before this object finishes
    /// initializing. Polling its actor-isolated state sidesteps that rather
    /// than fighting Swift's initialization checker over it.
    ///
    /// The poll deliberately outlives the `prepare()` call that started it and
    /// stops only when the load is terminal. Cancelling the caller — closing
    /// Settings, switching tabs — does not stop the actor's download, so
    /// stopping the poll with it would freeze the last sampled fraction on
    /// screen while the real work carried on invisibly.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncLoadState()
                switch self.loadState {
                case .ready, .failed:
                    return
                case .idle, .downloading, .loading:
                    break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func syncLoadState() async {
        let previous = loadState
        let state = await filterEngine.loadState
        loadState = state
        loadTiming = SpeechModelLoadTiming.advanced(
            current: loadTiming,
            from: previous,
            to: state,
            now: now()
        )
    }

    /// Asks macOS for the microphone, then records.
    ///
    /// `recorder.start()` only reads the authorization status and throws, so
    /// going straight to it meant the button in Settings could report
    /// "Microphone access denied" on a Mac that had never been asked — and,
    /// because `requestAccess` is also what registers an app in Privacy &
    /// Security › Microphone, left nothing there to switch on either
    /// (conrader/plainsay#49).
    public func start() async throws {
        guard await requestMicrophone() else { throw AudioRecorderError.microphoneDenied }
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

    /// Stops the recording. It does not stop the model load: `prepare()` runs
    /// on an actor that has no cancellation point, so claiming the load ended
    /// would be a second untruth on top of the frozen bar this replaced. The
    /// poll keeps running until the load is genuinely terminal.
    public func cancel() {
        isRecording = false
        recorder.cancel()
    }
}
