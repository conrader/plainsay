import CoreGraphics
import Foundation
import Testing
@testable import PlainsayCore

@Suite("Local dictation correction commands")
struct DictationCorrectionCommandTests {
    @Test("English and Polish corrections keep the original punctuation")
    func phrases() throws {
        let command = try DictationCorrectionCommand.parse("Change Tuesday to Thursday.")
        #expect(try command.localReplacement(in: "Meet Tuesday at 10:30.", undoText: nil) == "Meet Thursday at 10:30.")
        let polish = try DictationCorrectionCommand.parse("Zamień wtorek na czwartek.")
        #expect(try polish.localReplacement(in: "Spotkajmy się we wtorek.", undoText: nil) == "Spotkajmy się we czwartek.")
    }

    @Test("Quoted replacements preserve intentional punctuation and literal dollar signs")
    func quotes() throws {
        let command = try DictationCorrectionCommand.parse(#"Replace "hello" with "Hello!"."#)
        #expect(try command.localReplacement(in: "hello", undoText: nil) == "Hello!")
        let money = try DictationCorrectionCommand.parse("change $125 to $150")
        #expect(try money.localReplacement(in: "Budget: $125.", undoText: nil) == "Budget: $150.")
        let smart = try DictationCorrectionCommand.parse("Zmień “cześć” na “Cześć!”.")
        #expect(try smart.localReplacement(in: "cześć", undoText: nil) == "Cześć!")
    }

    @Test("Repeated or missing words are never guessed")
    func ambiguity() throws {
        let command = try DictationCorrectionCommand.parse("change Tuesday to Thursday")
        #expect(throws: DictationCorrectionError.ambiguousMatch) {
            try command.localReplacement(in: "Tuesday or next Tuesday", undoText: nil)
        }
        #expect(throws: DictationCorrectionError.noMatch) {
            try command.localReplacement(in: "Meet Monday.", undoText: nil)
        }
        #expect(throws: DictationCorrectionError.noMatch) {
            try DictationCorrectionCommand.replace("cat", "dog").localReplacement(in: "concatenate", undoText: nil)
        }
        #expect(throws: DictationCorrectionError.noMatch) {
            try DictationCorrectionCommand.replace("10", "11").localReplacement(in: "Meet at 10:30.", undoText: nil)
        }
        #expect(throws: DictationCorrectionError.noMatch) {
            try DictationCorrectionCommand.replace("5", "6").localReplacement(in: "Value 1.5", undoText: nil)
        }
        #expect(try DictationCorrectionCommand.replace("10", "11").localReplacement(in: "Value 10.", undoText: nil) == "Value 11.")
    }

    @Test("Undo needs a verified restoration value; broader requests remain explicit")
    func undoAndRewrite() throws {
        #expect(try DictationCorrectionCommand.parse("Undo that.") == .undo)
        #expect(try DictationCorrectionCommand.parse("Cofnij to!") == .undo)
        #expect(try DictationCorrectionCommand.undo.localReplacement(in: "dictation", undoText: "") == "")
        #expect(throws: DictationCorrectionError.nothingToUndo) {
            try DictationCorrectionCommand.undo.localReplacement(in: "dictation", undoText: nil)
        }
        #expect(try DictationCorrectionCommand.parse("Make it warmer") == .rewrite("Make it warmer"))
        #expect(throws: DictationCorrectionError.emptyCommand) { try DictationCorrectionCommand.parse(" \n") }
    }

    @Test("Insertion ranges use UTF-16 safely and reject split emoji or invalid offsets")
    @MainActor func ranges() {
        let original = "👋 hello café"
        #expect(DictationInsertionAnchor.replacing(original, range: NSRange(location: 3, length: 5), with: "cześć") == "👋 cześć café")
        #expect(DictationInsertionAnchor.replacing(original, range: NSRange(location: 1, length: 1), with: "x") == nil)
        #expect(DictationInsertionAnchor.replacing(original, range: NSRange(location: 99, length: 1), with: "x") == nil)
        #expect(DictationInsertionAnchor.replacing("e\u{301}", range: NSRange(location: 0, length: 1), with: "x") == nil)
        #expect(DictationInsertionAnchor.replacing("abc", range: NSRange(location: 3, length: 0), with: "def") == "abcdef")
    }
}

@MainActor
private final class CorrectionTarget: DictationReplacementTarget {
    let replacedText: String
    var received: [String] = []
    var error: Error?
    init(replacedText: String = "") { self.replacedText = replacedText }
    func replace(with text: String) async throws {
        if let error { throw error }
        received.append(text)
    }
}

@Suite("Verified correction sessions")
@MainActor
struct LastDictationTests {
    @Test("Corrections and undo restore each previous text, including a replaced selection")
    func undoStack() async throws {
        let target = CorrectionTarget(replacedText: "Previous selection")
        let dictation = LastDictation(text: "Meet Tuesday.", target: target)
        try await dictation.apply(dictation.proposal(replacement: "Meet Thursday."))
        #expect(dictation.text == "Meet Thursday.")
        #expect(dictation.undoText == "Meet Tuesday.")
        try await dictation.apply(dictation.proposal(replacement: "Meet Tuesday.", isUndo: true))
        #expect(dictation.undoText == "Previous selection")
        try await dictation.apply(dictation.proposal(replacement: "Previous selection", isUndo: true))
        #expect(dictation.undoText == nil)
        #expect(target.received == ["Meet Thursday.", "Meet Tuesday.", "Previous selection"])
    }

    @Test("A stale preview cannot be applied twice")
    func revisionGuard() async throws {
        let target = CorrectionTarget()
        let dictation = LastDictation(text: "Tuesday", target: target)
        let preview = dictation.proposal(replacement: "Thursday")
        try await dictation.apply(preview)
        await #expect(throws: DictationCorrectionError.stale) { try await dictation.apply(preview) }
        #expect(target.received == ["Thursday"])
    }

    @Test("Failure invalidates the destination without losing the original or advancing undo")
    func failedWrite() async {
        let target = CorrectionTarget()
        target.error = DictationCorrectionError.stale
        let dictation = LastDictation(text: "Tuesday", target: target)
        let revision = dictation.revision
        await #expect(throws: DictationCorrectionError.stale) { try await dictation.apply(dictation.proposal(replacement: "Thursday")) }
        #expect(dictation.text == "Tuesday")
        #expect(dictation.revision == revision)
        #expect(!dictation.canReplace)
        #expect(target.received.isEmpty)
    }

    @Test("An unverified paste supports preview but cannot replace or undo")
    func unverified() async {
        let dictation = LastDictation(text: "Tuesday")
        #expect(dictation.undoText == nil)
        #expect(!dictation.canReplace)
        await #expect(throws: DictationCorrectionError.stale) { try await dictation.apply(dictation.proposal(replacement: "Thursday")) }
    }

    @Test("Verified corrections update copyable history and preserve the raw transcript")
    func historyUpdate() {
        let history = TranscriptHistory(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let record = TranscriptRecord(text: "Tuesday", rawText: "um Tuesday", outcome: .inserted, durationSeconds: 2, targetApp: nil)
        history.add(record)
        history.updateCorrectedText(id: record.id, text: "Thursday")
        #expect(history.records.first?.text == "Thursday")
        #expect(history.records.first?.rawText == "um Tuesday")
        history.clear()
        history.updateCorrectedText(id: record.id, text: "Friday")
        #expect(history.records.isEmpty)
    }
}

@Suite("Correction capture pipeline", .serialized)
@MainActor
struct CorrectionCaptureTests {
    @MainActor
    private struct Harness {
        let recorder = FakeRecorder()
        let engine = FakeEngine()
        let inserter = FakeInserter()
        let history: TranscriptHistory
        let pending: PendingAudioStore
        let coordinator: DictationCoordinator

        init(engineOverride: (any TranscriptionEngine)? = nil) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("correction-test-\(UUID())")
            history = TranscriptHistory(directory: root.appendingPathComponent("history"))
            pending = PendingAudioStore(directory: root.appendingPathComponent("audio"))
            let settings = PlainsaySettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            settings.playFeedbackSounds = false
            settings.livePreviewEnabled = false
            let engine: any TranscriptionEngine = engineOverride ?? engine
            coordinator = DictationCoordinator(settings: settings, history: history, pendingAudio: pending,
                recorder: recorder, inserter: inserter, makeEngine: { _, _, _ in engine },
                makeCleaner: { _ in NoCleanup() }, microphoneAuthorized: { true }, usesInjectedEngine: true)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    @Test("A spoken correction neither pastes nor enters history nor replaces the last dictation")
    func separateCapture() async throws {
        let h = Harness()
        await h.coordinator.reloadModel()
        h.engine.transcript = "Meet Tuesday."
        h.coordinator.handleHotkeyEdge(.down(at: 0))
        h.coordinator.handleHotkeyEdge(.up(at: 1))
        try await waitUntil { h.coordinator.lastDictation != nil && !h.coordinator.phase.isBusy }
        let id = h.coordinator.lastDictation?.id
        h.engine.transcript = "Change Tuesday to Thursday."
        var result: Result<String, Error>?
        #expect(h.coordinator.beginCorrectionCapture { result = $0 })
        h.coordinator.finishCorrectionCapture()
        try await waitUntil { result != nil }
        #expect(try result?.get() == "Change Tuesday to Thursday.")
        #expect(h.inserter.inserted == ["Meet Tuesday."])
        #expect(h.history.records.count == 1)
        #expect(h.coordinator.lastDictation?.id == id)
        #expect(h.coordinator.lastTranscript == "Meet Tuesday.")
        #expect(h.pending.recoverable().isEmpty)
    }

    @Test("Cancelling capture does not leave a callback attached to the next ordinary dictation")
    func cancellation() async throws {
        let h = Harness()
        await h.coordinator.reloadModel()
        var callbacks = 0
        #expect(h.coordinator.beginCorrectionCapture { _ in callbacks += 1 })
        h.coordinator.cancelCorrectionCapture()
        #expect(callbacks == 1)
        #expect(!h.recorder.isRecording)
        #expect(!h.coordinator.isCapturingCorrection)
        h.engine.transcript = "An ordinary dictation."
        h.coordinator.handleHotkeyEdge(.down(at: 2))
        h.coordinator.handleHotkeyEdge(.up(at: 3))
        try await waitUntil { !h.inserter.inserted.isEmpty }
        #expect(callbacks == 1)
        #expect(h.inserter.inserted == ["An ordinary dictation."])
    }

    @Test("Short capture returns an error without writing recovery audio or history")
    func shortCapture() async throws {
        let h = Harness()
        await h.coordinator.reloadModel()
        h.recorder.duration = 0.1
        var result: Result<String, Error>?
        #expect(h.coordinator.beginCorrectionCapture { result = $0 })
        h.coordinator.finishCorrectionCapture()
        try await waitUntil { result != nil }
        #expect(throws: DictationCorrectionError.tooShort) { try result?.get() }
        #expect(h.history.records.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
        #expect(h.pending.recoverable().isEmpty)
    }

    @Test("Cancellation or shutdown during transcription discards the late command", arguments: [false, true])
    func lateCommand(shutdown: Bool) async throws {
        let engine = WaitingCorrectionEngine()
        let h = Harness(engineOverride: engine)
        await h.coordinator.reloadModel()
        var callbacks = 0
        var succeeded = false
        #expect(h.coordinator.beginCorrectionCapture {
            callbacks += 1
            if case .success = $0 { succeeded = true }
        })
        h.coordinator.finishCorrectionCapture()
        try await waitUntil { await engine.started }
        #expect(h.pending.recoverable().isEmpty)
        if shutdown { h.coordinator.stop() }
        else { h.coordinator.cancelCorrectionCapture() }
        await engine.release()
        try await waitUntil { !h.coordinator.phase.isBusy }
        #expect(callbacks == 1)
        #expect(!succeeded)
        #expect(h.inserter.inserted.isEmpty)
        #expect(h.history.records.isEmpty)
        #expect(h.coordinator.lastDictation == nil)
    }

    @Test("The correction shortcut consumes repeats and release but preserves normal Cmd-R")
    func shortcut() async {
        let monitor = HotkeyMonitor()
        var calls = 0
        monitor.onCorrectLastDictation = { calls += 1 }
        let flags = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
        #expect(monitor.handle(type: .keyDown, keyCode: 15, flags: flags, isAutorepeat: false))
        #expect(monitor.handle(type: .keyDown, keyCode: 15, flags: flags, isAutorepeat: true))
        #expect(monitor.handle(type: .keyUp, keyCode: 15, flags: 0, isAutorepeat: false))
        #expect(!monitor.handle(type: .keyDown, keyCode: 15, flags: CGEventFlags.maskCommand.rawValue, isAutorepeat: false))
        for _ in 0..<10 where calls == 0 { await Task.yield() }
        #expect(calls == 1)
    }
}

private actor WaitingCorrectionEngine: TranscriptionEngine {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func prepare() async throws {}
    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return "Change Tuesday to Thursday."
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
