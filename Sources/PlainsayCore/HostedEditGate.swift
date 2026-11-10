import Foundation

/// The gate in front of every hosted editing request: Voice Edit Preview and
/// the "Correct last dictation" Preview.
///
/// It reads the live private arm each time it is asked, never a value captured
/// when a window opened. So a window that was already open when the user armed
/// private dictation is refused at its next Preview, before an editor is even
/// constructed.
///
/// A request that is already running when private dictation is armed is
/// cancelled, and whatever it returns is discarded with the refusal message
/// instead of being shown. It was sent before the arm, so the arm cannot
/// recall it, but nothing more comes of it while private dictation is on.
@MainActor
public final class HostedEditGate {
    /// Nil when hosted editing may run now. The coordinator installs its live
    /// `editingRefusal` here; a standalone gate (previews, tests) is open.
    var refusal: @MainActor () -> String? = { nil }
    private var running: [UUID: Task<Void, Never>] = [:]

    public init() {}

    /// Throws `HostedEditRefused` when a hosted editing request must not start now.
    public func check() throws {
        if let message = refusal() { throw HostedEditRefused(message: message) }
    }

    /// Sends `request` to `editor` only if the gate is open now, and turns the
    /// reply (or failure) into `HostedEditRefused` if private dictation was
    /// armed while the request was out.
    public func send(_ request: VoiceEditRequest, to editor: any TextEditing) async throws -> String {
        try check()
        let reply: String
        do {
            reply = try await editor.edit(request)
        } catch {
            try check()
            throw error
        }
        try check()
        return reply
    }

    /// Remembers a running request so arming private dictation can cancel it.
    @discardableResult
    public func track(_ task: Task<Void, Never>) -> Task<Void, Never> {
        let id = UUID()
        running[id] = task
        Task { [weak self] in
            await task.value
            self?.running[id] = nil
        }
        return task
    }

    /// Cancels every running request. Called when private dictation is armed.
    func cancelAll() {
        let tasks = running.values
        running.removeAll()
        for task in tasks { task.cancel() }
    }

    var runningCount: Int { running.count }
}

/// A hosted editing request refused because private dictation is armed or in flight.
public struct HostedEditRefused: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
