import Foundation

/// Opt-in usage-statistics bookkeeping for standard dictations, kept out of
/// the coordinator body. Every call is a no-op without consent.
@MainActor
struct DictationUsage {
    private let statistics: UsageStatistics?
    private var generation: Int?
    private var language: String?

    init(statistics: UsageStatistics?) {
        self.statistics = statistics
    }

    /// A capture begun without consent, while private, or for a correction never counts.
    mutating func begin(isPrivate: Bool, isCorrection: Bool, language: String?) {
        generation = statistics?.beginDictation(isPrivate: isPrivate, isCorrection: isCorrection)
        self.language = language
    }

    /// A standard attempt that failed before any audio was captured.
    func fail(_ failure: UsageStatistics.Failure) {
        statistics?.record(generation, failures: [failure])
    }

    func attempt(seconds: Double, source: TranscriptionSource?) -> DictationUsageAttempt {
        DictationUsageAttempt(
            statistics: statistics, generation: generation, language: language, seconds: seconds, source: source
        )
    }
}

/// One captured recording on its way through the pipeline; `finish()` records it once.
@MainActor
final class DictationUsageAttempt {
    private let statistics: UsageStatistics?
    private let generation: Int?
    private let language: String?
    private let seconds: Double
    private let mode: UsageStatistics.Mode?
    private var attemptedPolishing = false
    private var failures: [UsageStatistics.Failure] = []

    init(statistics: UsageStatistics?, generation: Int?, language: String?, seconds: Double, source: TranscriptionSource?) {
        self.statistics = statistics
        self.generation = generation
        self.language = language
        self.seconds = seconds
        self.mode = switch source {
        case .onDevice: .local
        case .cloud: .cloud
        case .remote: .remote
        case nil: nil
        }
    }

    func fail(_ failure: UsageStatistics.Failure) {
        failures.append(failure)
    }

    func polishing(attempted: Bool, failed: Bool) {
        attemptedPolishing = attempted
        if failed { failures.append(.polishing) }
    }

    func insertion(_ outcome: TextInsertionOutcome) {
        switch outcome {
        case .noFocusedElement, .targetUnavailable: failures.append(.insertion)
        default: break
        }
    }

    func finish() {
        statistics?.record(
            generation, seconds: seconds, mode: mode,
            attemptedPolishing: attemptedPolishing, language: language, failures: failures
        )
    }
}
