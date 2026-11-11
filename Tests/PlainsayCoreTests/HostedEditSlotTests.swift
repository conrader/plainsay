import Foundation
import Testing
@testable import PlainsayCore

// REVIEW-sol (fix2): arming then disarming during a hosted Preview must not
// strand the Voice Edit or correction window busy, and a stale reply must not
// overwrite a newer request. Both App models run their Preview through
// `HostedEditSlot`; the App target has no test target, so `PreviewWindow`
// mirrors each model's busy/message handling around the real slot and gate.

/// A hosted editor whose answer the test scripts and releases by hand.
final class ScriptedEditor: TextEditing, @unchecked Sendable {
    enum Answer: Sendable { case reply, cancelled, failed }
    struct ProviderDown: LocalizedError { var errorDescription: String? { "Provider is down." } }

    let hold = TestHold()
    private let answer: Answer
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(_ answer: Answer) { self.answer = answer }

    func edit(_ request: VoiceEditRequest) async throws -> String {
        lock.withLock { count += 1 }
        // Ignores task cancellation on purpose, like a provider mid-response.
        await hold.wait()
        switch answer {
        case .reply: return "Edited: \(request.original)"
        case .cancelled: throw CancellationError()
        case .failed: throw ProviderDown()
        }
    }
}

enum EditingWindow: String, CaseIterable, Sendable { case voiceEdit, correction }

/// The busy/message/result state of one editing window, wired as the App model is.
@MainActor
private final class PreviewWindow {
    let kind: EditingWindow
    let gate: HostedEditGate
    let slot: HostedEditSlot
    var busy = false
    var message: String?
    var result: String?
    /// The correction window rejects a reply for a dictation that changed meanwhile.
    var dictationRevision = 0

    init(_ kind: EditingWindow, gate: HostedEditGate) {
        self.kind = kind
        self.gate = gate
        self.slot = HostedEditSlot(gate: gate)
    }

    /// Mirrors `VoiceEditModel.preview()` / `DictationCorrectionModel.preview()`.
    @discardableResult
    func preview(_ editor: any TextEditing) -> Task<Void, Never>? {
        slot.cancel()
        busy = false
        message = nil
        result = nil
        do {
            try gate.check()
            busy = true
            let revision = dictationRevision
            let kind = kind
            return slot.start(sampleSlotRequest, to: editor, onReply: { [weak self] reply in
                guard let self else { return }
                if kind == .correction, self.dictationRevision != revision { throw DictationCorrectionError.stale }
                self.result = reply
                self.busy = false
            }, onFailure: { [weak self] error in
                self?.message = error.localizedDescription
                self?.busy = false
            })
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Mirrors the models' Cancel button.
    func cancel() {
        slot.cancel()
        busy = false
    }
}

private let sampleSlotRequest = VoiceEditRequest(original: "Ship the build.", instruction: "Make it formal")
private let refusalMessage = PrivateDictationState.blocksEditingMessage

@Suite("Hosted Preview settles across arm and disarm", .serialized)
@MainActor
struct HostedEditSlotTests {
    private func makeWindow(_ kind: EditingWindow) async -> (PrivateHarness, PreviewWindow) {
        let harness = PrivateHarness()
        await harness.ready()
        return (harness, PreviewWindow(kind, gate: harness.coordinator.privateDictation.hostedEdits))
    }

    @Test("Arm → disarm → late success: busy clears with the refusal, the reply is dropped",
          arguments: EditingWindow.allCases)
    func lateSuccessAfterTransientArm(kind: EditingWindow) async throws {
        let (harness, window) = await makeWindow(kind)
        let editor = ScriptedEditor(.reply)
        let task = try #require(window.preview(editor))
        try await editor.hold.waitUntilEntered()
        #expect(window.busy)

        #expect(harness.coordinator.armPrivateNextDictation() == nil)
        harness.coordinator.disarmPrivate()
        editor.hold.release()
        await task.value

        #expect(!window.busy)
        #expect(window.result == nil)
        #expect(window.message == refusalMessage)
        #expect(!window.slot.isRunning)
    }

    @Test("Arm → disarm → provider-thrown cancellation or error: busy clears with the refusal",
          arguments: EditingWindow.allCases, [ScriptedEditor.Answer.cancelled, .failed])
    func lateFailureAfterTransientArm(kind: EditingWindow, answer: ScriptedEditor.Answer) async throws {
        let (harness, window) = await makeWindow(kind)
        let editor = ScriptedEditor(answer)
        let task = try #require(window.preview(editor))
        try await editor.hold.waitUntilEntered()

        harness.coordinator.armPrivateNextDictation()
        harness.coordinator.disarmPrivate()
        editor.hold.release()
        await task.value

        #expect(!window.busy)
        #expect(window.result == nil)
        #expect(window.message == refusalMessage)
    }

    @Test("A stale reply from the arm-cancelled request cannot overwrite the newer Preview",
          arguments: EditingWindow.allCases)
    func staleCompletionIgnored(kind: EditingWindow) async throws {
        let (harness, window) = await makeWindow(kind)
        let first = ScriptedEditor(.reply)
        let firstTask = try #require(window.preview(first))
        try await first.hold.waitUntilEntered()
        harness.coordinator.armPrivateNextDictation()
        harness.coordinator.disarmPrivate()

        let second = ScriptedEditor(.reply)
        let secondTask = try #require(window.preview(second))
        try await second.hold.waitUntilEntered()

        first.hold.release()
        await firstTask.value
        #expect(window.busy, "the stale request settled the newer one")
        #expect(window.message == nil)
        #expect(window.result == nil)

        second.hold.release()
        await secondTask.value
        #expect(!window.busy)
        #expect(window.message == nil)
        #expect(window.result == "Edited: Ship the build.")
    }

    @Test("A Preview the user cancelled drops its late reply and error",
          arguments: EditingWindow.allCases, [ScriptedEditor.Answer.reply, .failed])
    func userCancelDropsLateCompletion(kind: EditingWindow, answer: ScriptedEditor.Answer) async throws {
        let (_, window) = await makeWindow(kind)
        let editor = ScriptedEditor(answer)
        let task = try #require(window.preview(editor))
        try await editor.hold.waitUntilEntered()
        window.cancel()
        window.message = "after cancel"
        editor.hold.release()
        await task.value

        #expect(!window.busy)
        #expect(window.result == nil)
        #expect(window.message == "after cancel")
    }

    @Test("Without an arm, replies and errors settle as before", arguments: EditingWindow.allCases)
    func ordinaryPreviewSettles(kind: EditingWindow) async throws {
        let (_, window) = await makeWindow(kind)
        let failing = ScriptedEditor(.failed)
        failing.hold.release()
        await window.preview(failing)?.value
        #expect(!window.busy)
        #expect(window.message == "Provider is down.")

        let editor = ScriptedEditor(.reply)
        editor.hold.release()
        await window.preview(editor)?.value
        #expect(!window.busy)
        #expect(window.message == nil)
        #expect(window.result == "Edited: Ship the build.")
    }

    @Test("While armed, a Preview is refused before the editor is called", arguments: EditingWindow.allCases)
    func armedPreviewNeverDispatches(kind: EditingWindow) async throws {
        let (harness, window) = await makeWindow(kind)
        harness.coordinator.armPrivateNextDictation()
        let editor = ScriptedEditor(.reply)
        editor.hold.release()
        #expect(window.preview(editor) == nil)
        #expect(!window.busy)
        #expect(window.message == refusalMessage)
        #expect(editor.calls == 0)
    }

    @Test("The correction window still rejects a reply for a dictation that changed")
    func correctionStaleDictation() async throws {
        let (_, window) = await makeWindow(.correction)
        let editor = ScriptedEditor(.reply)
        let task = try #require(window.preview(editor))
        try await editor.hold.waitUntilEntered()
        window.dictationRevision += 1
        editor.hold.release()
        await task.value
        #expect(!window.busy)
        #expect(window.result == nil)
        #expect(window.message == DictationCorrectionError.stale.localizedDescription)
    }
}
