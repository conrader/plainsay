import Foundation

// Moved verbatim out of DictationCoordinator.swift to keep that file from
// growing (oneshot/R1 line budget). Behaviour unchanged.
extension DictationCoordinator {
    /// The gap before the next preview pass, given how long the last one took.
    ///
    /// Clamped at both ends: never faster than `previewInterval`, so a cheap
    /// pass on a two-second clip does not spin the engine continuously, and
    /// never slower than `previewMaximumInterval`, so a long recording still
    /// updates often enough to be worth showing.
    static func nextPreviewInterval(afterPassLasting duration: Duration) -> Duration {
        min(max(duration, previewInterval), previewMaximumInterval)
    }
}
