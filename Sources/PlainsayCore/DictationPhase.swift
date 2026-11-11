import Foundation

extension DictationCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        case recording
        /// Capture reached its ten-minute in-memory boundary and stopped
        /// automatically. The retained audio is moving through the normal
        /// transcription pipeline while the HUD explains why recording ended.
        case recordingLimitReached
        case transcribing
        case cleaning
        /// The hotkey was pressed while the selected speech model was still
        /// downloading or being prepared. The HUD renders `modelState` rather
        /// than treating this as a generic failure.
        case modelLoading
        /// Finished, but cleanup fell back to the raw transcript.
        case insertedRaw
        /// The text is safe on the clipboard, but it did not land anywhere on
        /// its own. The reason decides what the HUD says, because "nothing was
        /// focused" and "the window you dictated into is gone" need different
        /// answers from the person reading it.
        case savedToClipboard(ClipboardFallbackReason)
        /// The user deliberately abandoned an active recording with Escape.
        case cancelled
        case error(String)

        /// Why a dictation ended up on the clipboard rather than in a
        /// document.
        public enum ClipboardFallbackReason: Equatable, Sendable {
            /// Nothing anywhere was focused, so a synthetic Command-V had
            /// nowhere to land.
            case nothingFocused
            /// Something was focused, but not what the dictation was aimed at.
            /// The loss records which way it went wrong; the HUD does not,
            /// because "quit", "would not come forward" and "different window"
            /// all mean the same thing to the person waiting for their text.
            case targetGone(PasteTargetLoss)
        }

        public var isBusy: Bool {
            switch self {
            case .recording, .recordingLimitReached, .transcribing, .cleaning: true
            case .idle, .modelLoading, .insertedRaw, .savedToClipboard, .cancelled, .error: false
            }
        }
    }
}
