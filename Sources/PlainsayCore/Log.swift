import Foundation
import os

/// Structured logging for the dictation pipeline.
///
/// A dictation that vanishes is the worst failure this app has: you spoke, you
/// waited, and nothing came out — with no way to tell whether the audio, the
/// model, the network, or the paste was at fault. Every stage therefore logs
/// its outcome so `log show --predicate 'subsystem == "com.plainsay.dictation"'`
/// can answer that question after the fact.
public enum Log {
    public static let subsystem = "com.plainsay.dictation"

    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let insertion = Logger(subsystem: subsystem, category: "insertion")
    public static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
    public static let model = Logger(subsystem: subsystem, category: "model")

    /// Shell command that shows this app's logs, surfaced in the UI so the user
    /// does not have to know the incantation.
    public static let showCommand =
        #"log show --predicate 'subsystem == "com.plainsay.dictation"' --last 1h --info"#
}

/// Why a dictation produced no text. Recorded so silent drops become visible.
public enum DictationOutcome: String, Codable, Sendable {
    case inserted
    case insertedWithoutCleanup
    case tooShort
    case silence
    case transcriptionFailed
    case microphoneUnavailable
    case modelNotReady
    case insertionUnverified
    /// Transcribed on a later launch, after the original run was interrupted.
    case recovered
}
