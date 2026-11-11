import Foundation

// Moved verbatim out of DictationCoordinator.swift to keep that file from
// growing (oneshot/R1 line budget). Behaviour unchanged; only `private` became
// internal so the main file can still call it.
extension DictationCoordinator {
    /// What to say when someone presses the hotkey before the model is up.
    var modelStatusMessage: String {
        switch modelState {
        case .idle:
            Localization.coreString("coordinator.modelStatus.starting", fallback: "Starting the speech model…")
        case .downloading:
            Localization.coreFormat(
                "coordinator.modelStatus.downloading",
                fallback: "Downloading the speech model (%@). This happens once.",
                settings.model.approximateSize
            )
        case .loading:
            // The Neural Engine compile runs once per model and takes minutes.
            // Quitting restarts it from scratch, so say not to.
            Localization.coreString(
                "coordinator.modelStatus.preparing",
                fallback: "Preparing the speech model for the Neural Engine. This takes a few minutes the first time — leave Plainsay running."
            )
        case .ready:
            Localization.coreString("coordinator.modelStatus.ready", fallback: "Ready")
        case .failed(let message):
            Localization.coreFormat(
                "coordinator.modelStatus.failed", fallback: "Speech model failed to load: %@", message
            )
        }
    }
}
