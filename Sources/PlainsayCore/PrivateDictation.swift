import Foundation
import Observation

/// The arm switch for "Private next dictation", plus the in-memory fallback
/// for a private dictation that did not paste.
///
/// Memory only: nothing here is persisted, so every launch starts disarmed.
/// `DictationCoordinator` owns the rules for when a session freezes, refuses
/// or consumes the arm; this type keeps that state out of the coordinator
/// file and makes the arm/consume rules testable on their own.
@MainActor
@Observable
public final class PrivateDictationState {
    /// The next dictation that passes the hotkey guards will be private.
    /// Stays on through refusals, cancels, silence and transcription errors;
    /// only a finished private dictation or "turn off" clears it.
    public internal(set) var isArmed = false
    public let ephemeral: EphemeralDictation

    public init(ephemeral: EphemeralDictation = EphemeralDictation()) {
        self.ephemeral = ephemeral
    }

    /// Arms unless `refusal` says the private path cannot run. A refused arm
    /// changes nothing.
    func arm(unless refusal: PrivateDictationRefusal?) -> PrivateDictationRefusal? {
        if let refusal { return refusal }
        isArmed = true
        return nil
    }

    /// Turns the arm off. The Copy fallback is dropped too, unless a private
    /// session is still in flight and may yet need it.
    func disarm(sessionInFlight: Bool) {
        isArmed = false
        if !sessionInFlight { ephemeral.wipe() }
    }

    /// A private pipeline produced a non-empty transcript, inserted or not.
    func consume() {
        isArmed = false
    }

    public nonisolated static var blocksEditingMessage: String {
        Localization.coreString(
            "coordinator.private.blocksEditing",
            fallback: "Turn off private dictation to use Voice Edit or corrections."
        )
    }

    public nonisolated static var stillArmedMessage: String {
        Localization.coreString(
            "coordinator.private.stillArmed",
            fallback: "Still armed: the next dictation will be private."
        )
    }

    /// `message`, followed by P10 when the failed session was private.
    nonisolated static func notice(_ message: String, stillArmed: Bool) -> String {
        stillArmed ? "\(message) \(stillArmedMessage)" : message
    }

    public nonisolated static var onClipboardMessage: String {
        Localization.coreString(
            "coordinator.private.onClipboard",
            fallback: "Private dictation is on the clipboard. It is not in History."
        )
    }
}
