import Foundation

/// One editing window's hosted Preview request: Voice Edit or "Correct last
/// dictation". It holds at most one current request and settles it exactly once.
///
/// - The current request always settles: `onReply` with the reply, or
///   `onFailure` with the error, so the window can clear its busy state.
/// - A request that arming private dictation cancelled settles with
///   `HostedEditRefused`, even when private dictation was turned off again
///   before the provider answered. Its reply is never delivered.
/// - A request the window replaced or cancelled itself is stale: whatever it
///   returns later is dropped without calling either closure.
@MainActor
public final class HostedEditSlot {
    private let gate: HostedEditGate
    private var current: UUID?
    private var task: Task<Void, Never>?

    public init(gate: HostedEditGate) {
        self.gate = gate
    }

    /// True while the current request is out.
    public var isRunning: Bool { current != nil }

    /// Sends `request` through the gate, replacing any request still running.
    /// `onReply` may throw to reject a reply; the error goes to `onFailure`.
    @discardableResult
    public func start(
        _ request: VoiceEditRequest,
        to editor: any TextEditing,
        onReply: @escaping @MainActor (String) throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never> {
        cancel()
        let id = UUID()
        current = id
        let gate = gate
        let task = gate.track(Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await gate.send(request, to: editor)) }
            catch { result = .failure(error) }
            guard let self, self.current == id else { return }
            self.current = nil
            self.task = nil
            do {
                if let reason = gate.armCancellation(of: id) { throw HostedEditRefused(message: reason) }
                try onReply(try result.get())
            } catch {
                onFailure(error)
            }
        }, id: id)
        self.task = task
        return task
    }

    /// The window cancelled or invalidated its request: drop whatever it returns.
    public func cancel() {
        current = nil
        task?.cancel()
        task = nil
    }
}
