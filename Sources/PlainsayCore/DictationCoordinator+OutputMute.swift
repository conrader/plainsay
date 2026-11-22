import Foundation

/// Muting the Mac's output for the length of a recording.
extension DictationCoordinator {
    /// How long the start sound gets before the output is muted; muting at
    /// once would swallow it along with the music.
    static let muteDelayAfterStartSound: Duration = .milliseconds(300)

    func muteOutputIfWanted() {
        guard settings.muteOutputWhileRecording else { return }
        let delay = settings.playFeedbackSounds ? Self.muteDelayAfterStartSound : .zero
        muteTask?.cancel()
        muteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // A quick tap or Escape can end the recording before the delay
            // does; muting then would leave the Mac silent with nobody to undo it.
            guard !Task.isCancelled, let self, self.phase == .recording, self.recorder.isRecording else { return }
            self.outputMute.mute()
        }
    }

    func restoreOutput() {
        muteTask?.cancel()
        muteTask = nil
        outputMute.restore()
    }
}
