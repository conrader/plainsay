import Foundation

/// "Private next dictation" entry points. The session rules themselves live in
/// `DictationSessionPolicy`; the hooks that apply them stay in the pipeline in
/// `DictationCoordinator.swift`.
extension DictationCoordinator {
    /// Nil when a private dictation could start now (pure check, no I/O).
    public var privateRefusal: PrivateDictationRefusal? {
        DictationSessionPolicy.privateRefusal(
            preparedSource: preparedSource,
            configuredSource: settings.transcriptionSource,
            modelState: modelState
        )
    }

    /// Arms the next dictation, or returns why it cannot be private. Memory
    /// only: a relaunch is always disarmed.
    @discardableResult
    public func armPrivateNextDictation() -> PrivateDictationRefusal? {
        privateDictation.arm(unless: privateRefusal)
    }

    public func disarmPrivate() {
        privateDictation.disarm(sessionInFlight: sessionPolicy.privacy == .privateLocal)
    }

    /// Voice Edit and corrections may call a hosted editor, so they refuse
    /// while private is armed or in flight. Nil when they may run.
    public var editingRefusal: String? {
        guard privateDictation.isArmed || sessionPolicy.privacy == .privateLocal else { return nil }
        return PrivateDictationState.blocksEditingMessage
    }
}
