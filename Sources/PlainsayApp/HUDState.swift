import SwiftUI
import PlainsayCore

/// Everything the HUD draws, as a plain value.
///
/// The HUD takes this rather than the coordinator so it can be rendered — and
/// looked at — without a microphone, a model, or any permissions.
struct HUDState: Equatable {
    var phase: DictationCoordinator.Phase = .idle
    var modelState: SpeechModelLoadState = .idle
    var modelLoadTiming: SpeechModelLoadTiming?
    var levelHistory: [Float] = []
    var elapsed: TimeInterval = 0
    var livePreviewText: String = ""
    var recordingStyle: HotkeyRecordingStyle?
    /// A private dictation is in flight, or its result is still on screen.
    var isPrivate = false

    init(
        phase: DictationCoordinator.Phase = .idle,
        modelState: SpeechModelLoadState = .idle,
        modelLoadTiming: SpeechModelLoadTiming? = nil,
        levelHistory: [Float] = [],
        elapsed: TimeInterval = 0,
        livePreviewText: String = "",
        recordingStyle: HotkeyRecordingStyle? = nil,
        isPrivate: Bool = false
    ) {
        self.phase = phase
        self.modelState = modelState
        self.modelLoadTiming = modelLoadTiming
        self.levelHistory = levelHistory
        self.elapsed = elapsed
        self.livePreviewText = livePreviewText
        self.recordingStyle = recordingStyle
        self.isPrivate = isPrivate
    }

    @MainActor
    init(_ coordinator: DictationCoordinator) {
        phase = coordinator.phase
        modelState = coordinator.modelState
        modelLoadTiming = coordinator.modelLoadTiming
        levelHistory = coordinator.levelHistory
        elapsed = coordinator.elapsed
        livePreviewText = coordinator.livePreviewText
        recordingStyle = coordinator.recordingStyle
        // The policy resets when the work unit ends, but a private clipboard
        // result is still on screen for a few seconds after that.
        let showsPrivateResult: Bool
        if case .savedToClipboard = coordinator.phase {
            showsPrivateResult = coordinator.privateDictation.ephemeral.hasText
        } else {
            showsPrivateResult = false
        }
        isPrivate = coordinator.sessionPolicy.privacy == .privateLocal || showsPrivateResult
    }
}
