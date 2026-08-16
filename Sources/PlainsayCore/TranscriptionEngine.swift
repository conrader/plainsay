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
