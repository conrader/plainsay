import Foundation

/// Speech-to-text backend. Implementations can be local Core ML models or a
/// hosted transcription service; the dictation pipeline does not need to know.
public protocol TranscriptionEngine: Sendable {
    /// Load the model. Called once at launch — a cold load per dictation would
    /// add roughly a second to every insertion.
    func prepare() async throws

    /// - Parameters:
    ///   - samples: 16kHz mono float PCM.
    ///   - prompt: optional decoder conditioning (the user's glossary).
    /// - Returns: the transcript, or an empty string when nothing was said.
    func transcribe(samples: [Float], prompt: String?) async throws -> String

    /// Releases resident model resources when the user switches engines.
    func shutdown() async
}

public extension TranscriptionEngine {
    func shutdown() async {}
}

public enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            Localization.coreString("engine.modelNotLoaded", fallback: "Speech model is not loaded yet.")
        case .failed(let message):
            Localization.coreFormat("engine.transcriptionFailed", fallback: "Transcription failed: %@", message)
        }
    }
}

/// Loading state shared by every local and hosted speech engine.
public enum SpeechModelLoadState: Sendable, Equatable {
    case idle
    case downloading(progress: Double)
    /// Core ML is preparing the downloaded model. `nil` means that the
    /// underlying runtime cannot report determinate progress for this stage.
    case loading(progress: Double?)
    case ready
    case failed(String)

    /// Returns a finite fraction in the closed unit interval. Download APIs
    /// occasionally surface NaN while their total size is still unknown, so
    /// progress must be sanitized before it reaches SwiftUI's `ProgressView`.
    public static func clampedProgress(_ progress: Double) -> Double {
        if progress.isNaN { return 0 }
        if progress == .infinity { return 1 }
        if progress == -.infinity { return 0 }
        return min(max(progress, 0), 1)
    }
}

/// Wall-clock markers for the model-load phase currently in progress.
///
/// Views can derive a live elapsed duration from `startedAt` without the core
/// pipeline owning a repeating timer. `lastDownloadProgressAt` only advances
/// when the reported download fraction reaches a new high-water mark, so it
/// can distinguish real forward progress from a stalled or oscillating source.
public struct SpeechModelLoadTiming: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case downloading
        case preparing
    }

    public let phase: Phase
    public let startedAt: Date
    public let lastDownloadProgressAt: Date?
    /// High-water mark used to distinguish genuine forward movement from
    /// providers that briefly regress or oscillate between file subtotals.
    public let highestDownloadProgress: Double?

    public init(
        phase: Phase,
        startedAt: Date,
        lastDownloadProgressAt: Date?,
        highestDownloadProgress: Double? = nil
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.lastDownloadProgressAt = lastDownloadProgressAt
        self.highestDownloadProgress = highestDownloadProgress
    }

    /// Advances the phase markers for one state change, and returns `nil` once
    /// the load becomes terminal.
    ///
    /// Repeated progress callbacks keep the phase start stable; only a download
    /// fraction above the all-time high refreshes the liveness marker, because
    /// duplicate or regressing callbacks are not evidence that a stalled
    /// transfer is alive. Kept here rather than in a loader so that every
    /// model download in the app — transcription and voice filter alike —
    /// measures itself the same way.
    public static func advanced(
        current: SpeechModelLoadTiming?,
        from previousState: SpeechModelLoadState,
        to state: SpeechModelLoadState,
        now: Date
    ) -> SpeechModelLoadTiming? {
        switch state {
        case .idle, .ready, .failed:
            return nil

        case .downloading(let progress):
            guard let current, current.phase == .downloading else {
                return SpeechModelLoadTiming(
                    phase: .downloading,
                    startedAt: now,
                    lastDownloadProgressAt: now,
                    highestDownloadProgress: SpeechModelLoadState.clampedProgress(progress)
                )
            }

            let previousProgress: Double?
            if case .downloading(let value) = previousState {
                previousProgress = SpeechModelLoadState.clampedProgress(value)
            } else {
                previousProgress = nil
            }
            let currentProgress = SpeechModelLoadState.clampedProgress(progress)
            let previousHigh = current.highestDownloadProgress ?? previousProgress ?? 0
            let madeForwardProgress = currentProgress > previousHigh
            return SpeechModelLoadTiming(
                phase: .downloading,
                startedAt: current.startedAt,
                lastDownloadProgressAt: madeForwardProgress ? now : current.lastDownloadProgressAt,
                highestDownloadProgress: max(previousHigh, currentProgress)
            )

        case .loading:
            guard current?.phase != .preparing else { return current }
            return SpeechModelLoadTiming(
                phase: .preparing,
                startedAt: now,
                lastDownloadProgressAt: nil
            )
        }
    }
}

/// Pure policy for presenting a live model load without inventing an ETA.
/// Keeping the thresholds in Core makes the boundary behavior testable while
/// App remains responsible only for localized wording and controls.
public struct SpeechModelLoadWatchdog: Sendable, Equatable {
    public enum Attention: Sendable, Equatable {
        case downloadStalled
        case downloadActionRequired
        case firstPreparation
        case takingLonger
        case actionRequired
    }

    public enum RecoveryAction: Sendable, Equatable {
        case retry
        case restart
    }

    public static let downloadStallAfter: TimeInterval = 90
    public static let downloadActionRequiredAfter: TimeInterval = 5 * 60
    public static let firstPreparationMessageAfter: TimeInterval = 3 * 60
    public static let takingLongerAfter: TimeInterval = 8 * 60
    public static let actionRequiredAfter: TimeInterval = 15 * 60

    public let state: SpeechModelLoadState
    public let timing: SpeechModelLoadTiming?
    public let now: Date

    public init(state: SpeechModelLoadState, timing: SpeechModelLoadTiming?, now: Date) {
        self.state = state
        self.timing = timing
        self.now = now
    }

    public var elapsed: TimeInterval? {
        guard let timing else { return nil }
        return max(0, now.timeIntervalSince(timing.startedAt))
    }

    public var percentage: Int? {
        switch state {
        case .downloading(let progress):
            Self.percentage(progress)
        case .loading(let progress):
            progress.map(Self.percentage)
        case .idle, .ready, .failed:
            nil
        }
    }

    public var attention: Attention? {
        guard let timing, let elapsed else { return nil }
        switch timing.phase {
        case .downloading:
            guard let lastProgress = timing.lastDownloadProgressAt,
                  now.timeIntervalSince(lastProgress) >= Self.downloadStallAfter
            else { return nil }
            if now.timeIntervalSince(lastProgress) >= Self.downloadActionRequiredAfter {
                return .downloadActionRequired
            }
            return .downloadStalled
        case .preparing:
            if elapsed >= Self.actionRequiredAfter { return .actionRequired }
            if elapsed >= Self.takingLongerAfter { return .takingLonger }
            if elapsed >= Self.firstPreparationMessageAfter { return .firstPreparation }
            return nil
        }
    }

    public var recoveryAction: RecoveryAction? {
        if case .failed = state { return .retry }
        if attention == .downloadStalled { return .retry }
        if attention == .downloadActionRequired || attention == .actionRequired { return .restart }
        return nil
    }

    public static func timecode(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func percentage(_ value: Double) -> Int {
        Int((SpeechModelLoadState.clampedProgress(value) * 100).rounded())
    }
}

/// On-device speech models available in the Speech settings.
///
/// The Whisper raw values are unchanged so preferences written by earlier
/// versions decode into this broader model type without a migration.
public enum OnDeviceModel: String, Codable, CaseIterable, Sendable {
    case baseEN = "openai_whisper-base.en"
    case smallEN = "openai_whisper-small.en"
    case distilLargeV3Turbo = "distil-whisper_distil-large-v3_turbo_600MB"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case parakeetTDT06BV3 = "nvidia_parakeet-tdt-0.6b-v3"

    public var displayName: String {
        switch self {
        case .baseEN:
            Localization.coreString("model.displayName.base", fallback: "Base (English) — fastest, least accurate")
        case .smallEN:
            Localization.coreString("model.displayName.small", fallback: "Small (English) — good balance")
        case .distilLargeV3Turbo:
            Localization.coreString(
                "model.displayName.distilLargeV3Turbo",
                fallback: "Whisper Distil Large v3 Turbo — fast, multilingual"
            )
        case .largeV3Turbo:
            Localization.coreString(
                "model.displayName.largeV3Turbo", fallback: "Whisper Large v3 Turbo — accurate, multilingual"
            )
        case .parakeetTDT06BV3:
            Localization.coreString(
                "model.displayName.parakeetTDT06BV3",
                fallback: "NVIDIA Parakeet TDT 0.6B v3 — recommended for Polish + English"
            )
        }
    }

    public var approximateSize: String {
        switch self {
        case .baseEN: Localization.coreString("model.size.base", fallback: "150 MB")
        case .smallEN: Localization.coreString("model.size.small", fallback: "480 MB")
        case .distilLargeV3Turbo: Localization.coreString("model.size.distilLargeV3Turbo", fallback: "600 MB")
        case .largeV3Turbo: Localization.coreString("model.size.largeV3Turbo", fallback: "632 MB")
        case .parakeetTDT06BV3: Localization.coreString("model.size.parakeetTDT06BV3", fallback: "~475 MB")
        }
    }

    /// The Core ML identifier WhisperKit understands, or nil for models served
    /// by a different local runtime.
    public var whisperKitModelID: String? {
        switch self {
        case .baseEN, .smallEN, .distilLargeV3Turbo, .largeV3Turbo:
            rawValue
        case .parakeetTDT06BV3:
            nil
        }
    }

    public var supportsDecoderPrompt: Bool {
        whisperKitModelID != nil
    }

    public var isSupportedOnCurrentHardware: Bool {
        switch self {
        case .parakeetTDT06BV3:
            #if arch(arm64)
            true
            #else
            false
            #endif
        default:
            true
        }
    }

    /// English-only models must not be asked to detect a language.
    public var isEnglishOnly: Bool {
        switch self {
        case .baseEN, .smallEN: true
        case .distilLargeV3Turbo, .largeV3Turbo, .parakeetTDT06BV3: false
        }
    }
}

/// Source compatibility for code that constructed WhisperKitEngine directly.
public typealias WhisperModel = OnDeviceModel

/// Bare markers Whisper emits for non-speech audio, after annotation stripping.
///
/// Deliberately excludes Whisper's silence hallucinations ("Thank you.", "you"):
/// suppressing those would eat real dictation, and the minimum-duration guard
/// plus `noSpeechThreshold` already cover actual silence.
let nonSpeechMarkers: Set<String> = ["", ".", "-", "..."]

/// Strips Whisper's bracketed sound annotations and decides whether anything
/// meaningful was actually said.
public func normalizeTranscript(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Drop annotations like [BLANK_AUDIO], (upbeat music), ♪ ... ♪
    let patterns = [#"\[[^\]]*\]"#, #"\([^\)]*\)"#, #"♪[^♪]*♪"#]
    for pattern in patterns {
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    text = text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // Whisper's stock hallucinations on silence.
    if nonSpeechMarkers.contains(text) { return "" }
    return text
}
