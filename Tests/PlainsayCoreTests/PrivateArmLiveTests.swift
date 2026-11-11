import Foundation
import Testing
@testable import PlainsayCore

// Review fixes for "Private next dictation" (REVIEW-sol findings 1–4):
// editing windows that were open before arming, the "Still armed" notice read
// from the live arm, P10 on cancel / too-short, and the no-growth line gate.

// MARK: - Fakes

/// A suspension point the test opens by hand, so a transcription or an editor
/// request can be caught "in flight".
final class TestHold: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isReleased = false

    var entered: Bool { lock.withLock { hasEntered } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                hasEntered = true
                if isReleased { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isReleased = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }

    /// Polls until something is suspended here; fails the test on timeout.
    @MainActor
    func waitUntilEntered(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !entered {
            guard ContinuousClock.now < deadline else {
                Issue.record("nothing reached the hold within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Stands in for a hosted editor (Plainsay Cloud, OpenAI, Anthropic…).
final class CountingEditor: TextEditing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let hold: TestHold?

    init(hold: TestHold? = nil) { self.hold = hold }

    var calls: Int { lock.withLock { count } }

    func edit(_ request: VoiceEditRequest) async throws -> String {
        lock.withLock { count += 1 }
        await hold?.wait()
        return "Edited: \(request.original)"
    }
}

private let sampleRequest = VoiceEditRequest(original: "Ship the build.", instruction: "Make it formal")

/// What `check()` threw, or nil when the gate is open.
@MainActor
private func refusal(_ gate: HostedEditGate) -> HostedEditRefused? {
    do { try gate.check(); return nil } catch { return error as? HostedEditRefused }
}

@MainActor
private final class OutcomeBox {
    var outcome: Result<String, Error>?
}

// MARK: - 1. Editing windows opened before arming

@Suite("Private arm is read live", .serialized)
@MainActor
struct PrivateArmLiveTests {
    @Test("1. A window opened before arming has its Preview refused before any editor call")
    func previewAfterArmingIsRefused() async throws {
        let harness = PrivateHarness()
        await harness.ready()
        // What a Voice Edit / correction window holds from the moment it opens.
        let gate = harness.coordinator.privateDictation.hostedEdits
        let editor = CountingEditor()

        #expect(try await gate.send(sampleRequest, to: editor) == "Edited: Ship the build.")
        #expect(editor.calls == 1)

        #expect(harness.coordinator.armPrivateNextDictation() == nil)
        #expect(refusal(gate) == HostedEditRefused(message: PrivateDictationState.blocksEditingMessage))
        do {
            _ = try await gate.send(sampleRequest, to: editor)
            Issue.record("a hosted request was sent while private dictation was armed")
        } catch {
            #expect(error is HostedEditRefused)
        }
        #expect(editor.calls == 1)

        harness.coordinator.disarmPrivate()
        #expect(try await gate.send(sampleRequest, to: editor) == "Edited: Ship the build.")
        #expect(editor.calls == 2)
    }

    @Test("1. Arming cancels a running hosted request and its reply is discarded")
    func armingCancelsRunningRequest() async throws {
        let harness = PrivateHarness()
        await harness.ready()
        let gate = harness.coordinator.privateDictation.hostedEdits
        let hold = TestHold()
        let editor = CountingEditor(hold: hold)

        let box = OutcomeBox()
        let task = gate.track(Task {
            do { box.outcome = .success(try await gate.send(sampleRequest, to: editor)) } catch { box.outcome = .failure(error) }
        })
        try await hold.waitUntilEntered()
        #expect(gate.runningCount == 1)

        harness.coordinator.armPrivateNextDictation()
        #expect(task.isCancelled)
        hold.release()
        await task.value

        guard case .failure(let error) = box.outcome else {
            Issue.record("the reply was delivered after arming: \(String(describing: box.outcome))")
            return
        }
        #expect(error as? HostedEditRefused == HostedEditRefused(message: PrivateDictationState.blocksEditingMessage))
        #expect(gate.runningCount == 0)
    }

    @Test("1. Disarming mid-session still refuses editing until the private session ends")
    func inFlightPrivateSessionRefusesEditing() async throws {
        let harness = PrivateHarness()
        let hold = TestHold()
        harness.engine.hold = hold
        await harness.ready()
        let gate = harness.coordinator.privateDictation.hostedEdits

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await hold.waitUntilEntered()
        harness.coordinator.disarmPrivate()
        #expect(!harness.coordinator.privateDictation.isArmed)
        #expect(refusal(gate) != nil)

        hold.release()
        try await harness.settle()
        #expect(harness.coordinator.sessionPolicy == .standard)
        #expect(refusal(gate) == nil)
    }

    // MARK: - 2. The future-session claim follows the live arm

    @Test("2. Disarm during a suspended private transcription, then silence: no 'still armed' claim")
    func disarmThenSilence() async throws {
        let harness = PrivateHarness()
        harness.engine.transcript = ""
        let hold = TestHold()
        harness.engine.hold = hold
        await harness.ready()

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await hold.waitUntilEntered()
        #expect(harness.coordinator.sessionPolicy.privacy == .privateLocal)
        harness.coordinator.disarmPrivate()
        #expect(harness.coordinator.sessionPolicy.privacy == .privateLocal)  // in-flight policy stays frozen
        hold.release()
        try await harness.settle()

        #expect(!harness.coordinator.privateDictation.isArmed)
        #expect(harness.coordinator.phase == .idle)
        #expect(harness.coordinator.lastErrorMessage?.contains(PrivateDictationState.stillArmedMessage) != true)
        #expect(harness.history.records.isEmpty)  // still private: nothing written
    }

    @Test("2. Disarm during a suspended private transcription, then an error: the error alone")
    func disarmThenError() async throws {
        let harness = PrivateHarness()
        harness.engine.error = ProbeError()
        let hold = TestHold()
        harness.engine.hold = hold
        await harness.ready()

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await hold.waitUntilEntered()
        harness.coordinator.disarmPrivate()
        hold.release()
        try await harness.settle()

        #expect(!harness.coordinator.privateDictation.isArmed)
        #expect(harness.coordinator.phase == .error("probe failure"))
        #expect(harness.history.records.isEmpty)
    }

    @Test("2. Re-arming during the session restores the claim, because it is true again")
    func rearmThenSilence() async throws {
        let harness = PrivateHarness()
        harness.engine.transcript = ""
        let hold = TestHold()
        harness.engine.hold = hold
        await harness.ready()

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await hold.waitUntilEntered()
        harness.coordinator.disarmPrivate()
        #expect(harness.coordinator.armPrivateNextDictation() == nil)
        hold.release()
        try await harness.settle()

        #expect(harness.coordinator.privateDictation.isArmed)
        #expect(harness.coordinator.phase == .error(PrivateDictationState.stillArmedMessage))
    }

    // MARK: - 3. P10 on cancel and too-short

    @Test("3. Cancelling a private recording keeps the arm and says so")
    func cancelShowsStillArmed() async throws {
        let harness = PrivateHarness()
        await harness.ready()
        harness.coordinator.armPrivateNextDictation()
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(harness.coordinator.cancelDictation())
        try await harness.settle()

        #expect(harness.coordinator.privateDictation.isArmed)
        #expect(harness.coordinator.phase == .error(PrivateDictationState.stillArmedMessage))
        #expect(harness.history.records.isEmpty)
    }

    @Test("3. Cancelling after a disarm, or a normal recording, shows a plain cancel")
    func cancelWithoutArmIsPlain() async throws {
        let disarmed = PrivateHarness()
        await disarmed.ready()
        disarmed.coordinator.armPrivateNextDictation()
        disarmed.coordinator.handleHotkeyEdge(.down(at: 0))
        disarmed.coordinator.disarmPrivate()
        #expect(disarmed.coordinator.cancelDictation())
        #expect(disarmed.coordinator.phase == .cancelled)

        let normal = PrivateHarness()
        await normal.ready()
        normal.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(normal.coordinator.cancelDictation())
        #expect(normal.coordinator.phase == .cancelled)
    }

    @Test("3. A too-short private recording keeps the arm and says so; a normal one stays quiet")
    func tooShortShowsStillArmed() async throws {
        let armed = PrivateHarness()
        armed.recorder.duration = 0.1
        await armed.ready()
        armed.coordinator.armPrivateNextDictation()
        armed.dictate()
        try await armed.settle()
        #expect(armed.coordinator.privateDictation.isArmed)
        #expect(armed.coordinator.phase == .error(PrivateDictationState.stillArmedMessage))
        #expect(armed.history.records.isEmpty)

        let normal = PrivateHarness()
        normal.recorder.duration = 0.1
        await normal.ready()
        normal.dictate()
        try await normal.settle()
        #expect(normal.coordinator.phase == .idle)
        #expect(normal.history.records.map(\.outcome) == [.tooShort])
    }
}

// MARK: - Source-level guards (App wiring and the line gate)

@Suite("Private dictation source guards")
struct PrivateDictationSourceGuards {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func lineCount(_ relative: String) throws -> Int {
        try source(relative).reduce(into: 0) { count, character in if character == "\n" { count += 1 } }
    }

    /// The App target has no test target, so this keeps both Preview paths on
    /// the gate: checked before the editor is built, and sent through it.
    @Test("1. Both editing windows check the live gate and send through it")
    func editingWindowsUseGate() throws {
        for path in ["Sources/PlainsayApp/VoiceEditWindowController.swift", "Sources/PlainsayApp/DictationCorrectionWindow.swift"] {
            let text = try source(path)
            #expect(!text.contains("editor.edit("), "\(path) calls the editor directly")
            #expect(text.contains("previewRequest.start(request, to: editor"), "\(path) does not send through the slot")
            #expect(text.contains(".check()"), "\(path) does not check the gate before building an editor")
            #expect(text.contains("previewRequest.cancel()"), "\(path) does not drop a cancelled Preview")
            #expect(!text.contains("Task.checkCancellation()"), "\(path) can exit a Preview without settling busy")
        }
        let slot = try source("Sources/PlainsayCore/HostedEditSlot.swift")
        #expect(slot.contains("gate.send(request, to: editor)") && slot.contains("gate.track(Task"))
        #expect(try source("Sources/PlainsayApp/AppModel.swift").contains("editGate: coordinator.privateDictation.hostedEdits"))
    }

    /// SPEC §3.0/§4 and §3.2: no growth against the R0 base (a5cd2b7).
    @Test("4. The coordinator and SettingsView are no larger than at the R0 base")
    func noGrowth() throws {
        #expect(try lineCount("Sources/PlainsayCore/DictationCoordinator.swift") <= 1304)
        #expect(try lineCount("Sources/PlainsayApp/SettingsView.swift") <= 784)
        let helpers = [
            "Sources/PlainsayCore/DictationCoordinator+CloudCredentials.swift",
            "Sources/PlainsayCore/DictationCoordinator+ModelStatus.swift",
            "Sources/PlainsayCore/DictationCoordinator+Private.swift",
            "Sources/PlainsayCore/HostedEditGate.swift",
            "Sources/PlainsayCore/HostedEditSlot.swift",
            "Sources/PlainsayCore/PrivateDictation.swift",
            "Sources/PlainsayApp/HistoryView.swift",
            "Sources/PlainsayApp/VoiceEditWindowController.swift",
            "Sources/PlainsayApp/DictationCorrectionWindow.swift",
        ]
        for path in helpers { #expect(try lineCount(path) <= 500, "\(path) crossed 500 lines") }
    }
}
