import Foundation

/// How the hotkey behaves.
public enum HotkeyMode: String, Codable, Sendable, CaseIterable {
    /// Quick tap latches recording on; holding past the threshold is push-to-talk.
    case hybrid
    /// Recording lasts exactly as long as the key is held.
    case holdOnly
    /// Each press toggles recording.
    case toggleOnly

    public var displayName: String {
        switch self {
        case .hybrid: Localization.coreString("hotkeyMode.displayName.hybrid", fallback: "Hold or tap (recommended)")
        case .holdOnly: Localization.coreString("hotkeyMode.displayName.holdOnly", fallback: "Hold to talk")
        case .toggleOnly: Localization.coreString("hotkeyMode.displayName.toggleOnly", fallback: "Tap to toggle")
        }
    }
}

public enum HotkeyEdge: Sendable, Equatable {
    case down(at: TimeInterval)
    case up(at: TimeInterval)
}

public enum DictationCommand: Sendable, Equatable {
    case start
    case stop
    case none
}

/// Pure hold-vs-tap disambiguation. No timers, no I/O — feed it edges, get commands.
///
/// In `.hybrid` mode a press released faster than `tapThreshold` latches recording
/// on until the next press; a longer press is push-to-talk and ends on release.
public struct HotkeyStateMachine: Sendable {
    public var mode: HotkeyMode
    public let tapThreshold: TimeInterval

    private enum State: Equatable {
        case idle
        /// Key is held, recording. Carries the press timestamp.
        case holding(since: TimeInterval)
        /// Recording continues with the key released (tap-latched).
        case latched
        /// Latch was just ended by a press; swallow the matching release.
        case endingAwaitingUp
    }

    private var state: State = .idle

    public init(mode: HotkeyMode = .hybrid, tapThreshold: TimeInterval = 0.25) {
        self.mode = mode
        self.tapThreshold = tapThreshold
    }

    public var isRecording: Bool {
        switch state {
        case .holding, .latched: true
        case .idle, .endingAwaitingUp: false
        }
    }

    public mutating func handle(_ edge: HotkeyEdge) -> DictationCommand {
        switch mode {
        case .holdOnly: return handleHoldOnly(edge)
        case .toggleOnly: return handleToggleOnly(edge)
        case .hybrid: return handleHybrid(edge)
        }
    }

    /// Abandon any in-flight press without emitting a command — used when the
    /// event tap is torn down or the mode changes mid-press.
    public mutating func reset() {
        state = .idle
    }

    private mutating func handleHoldOnly(_ edge: HotkeyEdge) -> DictationCommand {
        switch (state, edge) {
        case (.idle, .down(let t)):
            state = .holding(since: t)
            return .start
        case (.holding, .up):
            state = .idle
            return .stop
        default:
            return .none
        }
    }

    private mutating func handleToggleOnly(_ edge: HotkeyEdge) -> DictationCommand {
        switch (state, edge) {
        case (.idle, .down):
            state = .latched
            return .start
        case (.latched, .down):
            state = .idle
            return .stop
        default:
            return .none
        }
    }

    private mutating func handleHybrid(_ edge: HotkeyEdge) -> DictationCommand {
        switch (state, edge) {
        case (.idle, .down(let t)):
            state = .holding(since: t)
            return .start

        case (.holding(let start), .up(let t)):
            // A quick tap latches; anything longer was push-to-talk.
            if t - start < tapThreshold {
                state = .latched
                return .none
            }
            state = .idle
            return .stop

        // Pressing again while latched ends the dictation.
        case (.latched, .down):
            state = .endingAwaitingUp
            return .stop

        case (.endingAwaitingUp, .up):
            state = .idle
            return .none

        default:
            return .none
        }
    }
}
