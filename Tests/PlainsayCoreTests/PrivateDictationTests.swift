import AppKit
import Foundation
import Testing
@testable import PlainsayCore

// Tests for "Private next dictation" (spec-oneshot-xreview/SPEC.fixed.md §4)
// and the shared session-policy resolver (R1). Same harness pattern as
// PipelineTests, with an injectable pending-audio directory, a probing engine
// and a controllable clock for the in-memory Copy fallback.

// MARK: - Fakes

/// Records what was on disk in the pending-audio folder at the moment it was
/// asked to transcribe, i.e. *during* the session.
final class PrivateProbeEngine: TranscriptionEngine, @unchecked Sendable {
    var transcript = "um so the thing is uh it works"
    var error: Error?
    var prepareError: Error?
    var pendingDirectory: URL?
    /// When set, `transcribe` suspends here until the test releases it.
    var hold: TestHold?
    private(set) var pendingFilesDuringTranscribe: [Int] = []

    func prepare() async throws {
        if let prepareError { throw prepareError }
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        if let pendingDirectory {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? []
            pendingFilesDuringTranscribe.append(files.filter { $0.hasSuffix(".f32") }.count)
        }
        await hold?.wait()
        if let error { throw error }
        return normalizeTranscript(transcript)
    }
}

struct ProbeError: LocalizedError {
    var errorDescription: String? { "probe failure" }
}

@MainActor
final class PrivateTestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
struct PrivateHarness {
    let settings: PlainsaySettings
    let recorder = FakeRecorder()
    let engine = PrivateProbeEngine()
    let cleaner = FakeCleaner()
    let cleanerBuilds: CaptureCount
    let inserter = FakeInserter()
    let history: TranscriptHistory
    let historyFile: URL
    let pendingDirectory: URL
    let pendingAudio: PendingAudioStore
    let clock: PrivateTestClock
    let coordinator: DictationCoordinator

    init(injectedSource: TranscriptionSource = .onDevice, terms: [String] = []) {
        let suite = UserDefaults(suiteName: "plainsay.private.tests.\(UUID().uuidString)")!
        let settings = PlainsaySettings(defaults: suite)
        settings.dictionary = TermDictionary(terms: terms)
        settings.playFeedbackSounds = false
        settings.transcriptionSource = .onDevice
        self.settings = settings

        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-private-\(UUID().uuidString)", isDirectory: true)
        let history = TranscriptHistory(directory: base.appendingPathComponent("history", isDirectory: true))
        self.history = history
        historyFile = base.appendingPathComponent("history", isDirectory: true).appendingPathComponent("history.json")
        pendingDirectory = base.appendingPathComponent("pending", isDirectory: true)
        pendingAudio = PendingAudioStore(directory: pendingDirectory)
        engine.pendingDirectory = pendingDirectory

        let clock = PrivateTestClock()
        self.clock = clock
        let builds = CaptureCount()
        cleanerBuilds = builds

        let engine = self.engine
        let cleaner = self.cleaner
        coordinator = DictationCoordinator(
            settings: settings,
            history: history,
            pendingAudio: pendingAudio,
            cloud: PlainsayCloudClient(baseURL: "https://cloud.invalid.plainsay.tests", tokenStore: PrivateTokenStore()),
            recorder: recorder,
            inserter: inserter,
            makeEngine: { _, _, _ in engine },
            makeCleaner: { _ in
                builds.value += 1
                return cleaner
            },
            microphoneAuthorized: { true },
            usesInjectedEngine: true,
            injectedSource: injectedSource,
            privateDictation: PrivateDictationState(ephemeral: EphemeralDictation(now: { clock.now }))
        )
    }

    func ready() async {
        await coordinator.reloadModel()
    }

    func dictate(at start: TimeInterval = 0) {
        coordinator.handleHotkeyEdge(.down(at: start))
        coordinator.handleHotkeyEdge(.up(at: start + 1))
    }

    /// Settled = not recording, not busy, and the work unit has ended (the
    /// frozen policy resets to `.standard` exactly then). Fails the test on timeout.
    func settle(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !recorder.isRecording, !coordinator.phase.isBusy, coordinator.sessionPolicy == .standard {
                try await Task.sleep(for: .milliseconds(20))
                if !coordinator.phase.isBusy, coordinator.sessionPolicy == .standard { return }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the coordinator did not settle within \(timeout): phase \(coordinator.phase), policy \(coordinator.sessionPolicy)")
    }

    func seedHistory() {
        history.add(TranscriptRecord(text: "Lunch at noon.", rawText: "lunch at noon", outcome: .inserted, durationSeconds: 1, targetApp: "com.example.a"))
        history.add(TranscriptRecord(text: "Ship the build.", rawText: "ship the build", outcome: .inserted, durationSeconds: 1, targetApp: "com.example.b"))
    }

    func pendingFileCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? []
        return files.filter { $0.hasSuffix(".f32") }.count
    }
}

private final class PrivateTokenStore: CloudTokenStoring, @unchecked Sendable {
    var token: String?
}

// MARK: - Pipeline

@Suite("Private next dictation", .serialized)
@MainActor
struct PrivateDictationTests {
    @Test("2. A private dictation leaves History records and history.json untouched")
    func noHistory() async throws {
        let harness = PrivateHarness()
        await harness.ready()
        harness.seedHistory()
        let before = harness.history.records
        let bytes = try Data(contentsOf: harness.historyFile)
        let mtime = try FileManager.default.attributesOfItem(atPath: harness.historyFile.path)[.modificationDate] as? Date

        #expect(harness.coordinator.armPrivateNextDictation() == nil)
        harness.dictate()
        try await harness.settle()

        #expect(harness.inserter.inserted.count == 1)
        #expect(harness.history.records.map(\.id) == before.map(\.id))
        #expect(harness.history.records.map(\.outcome) == before.map(\.outcome))
        #expect(try Data(contentsOf: harness.historyFile) == bytes)
        let after = try FileManager.default.attributesOfItem(atPath: harness.historyFile.path)[.modificationDate] as? Date
        #expect(after == mtime)
    }

    @Test("3. No crash-recovery audio during or after a private session; a normal one still stages")
    func noRecoveryAudio() async throws {
        let harness = PrivateHarness()
        await harness.ready()

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await harness.settle()
        #expect(harness.engine.pendingFilesDuringTranscribe == [0])
        #expect(harness.pendingFileCount() == 0)

        harness.dictate(at: 10)
        try await harness.settle()
        #expect(harness.engine.pendingFilesDuringTranscribe == [0, 1])
        #expect(harness.pendingFileCount() == 0)
    }

    @Test("4. No cleaner is built, even with Plainsay Polishing and translation configured")
    func noCleaner() async throws {
        let harness = PrivateHarness(terms: ["Plainsay"])
        harness.settings.cleanupEnabled = true
        harness.settings.cleanupProvider = .plainsay
        harness.settings.translationTargetLanguage = "de"
        harness.settings.emailModeEnabled = true
        harness.engine.transcript = "i dictate with plainsay"
        await harness.ready()

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await harness.settle()

        let expected = sanitizeForInsertion(
            harness.settings.dictionary.applyCorrections(to: normalizeTranscript("i dictate with plainsay"))
        )
        #expect(harness.cleanerBuilds.value == 0)
        #expect(harness.cleaner.received == nil)
        #expect(harness.inserter.inserted == [expected])
    }

    @Test("5. An armed dictation that can no longer be private records nothing and stays armed")
    func refusalKeepsArm() async throws {
        let harness = PrivateHarness()
        await harness.ready()
        harness.seedHistory()
        let count = harness.history.records.count
        #expect(harness.coordinator.armPrivateNextDictation() == nil)

        harness.settings.transcriptionSource = .cloud
        harness.coordinator.handleHotkeyEdge(.down(at: 0))

        #expect(!harness.recorder.isRecording)
        #expect(harness.recorder.stopCount == 0)
        #expect(harness.coordinator.phase == .error(PrivateDictationRefusal.refusedMessage))
        #expect(harness.coordinator.privateDictation.isArmed)
        #expect(harness.history.records.count == count)
        #expect(harness.coordinator.sessionPolicy == .standard)
    }

    @Test("Arming is refused outright when the prepared engine is not on-device")
    func armRefusedForCloud() async {
        let harness = PrivateHarness(injectedSource: .cloud)
        await harness.ready()
        #expect(harness.coordinator.preparedSource == .cloud)
        #expect(harness.coordinator.armPrivateNextDictation() == .notOnDevice)
        #expect(!harness.coordinator.privateDictation.isArmed)
    }

    @Test("6. A Speech switch after arming refuses the press; a failed reload clears the prepared source")
    func midArmSourceSwitch() async throws {
        let harness = PrivateHarness()
        await harness.ready()
        #expect(harness.coordinator.preparedSource == .onDevice)
        harness.coordinator.armPrivateNextDictation()

        harness.settings.transcriptionSource = .cloud
        await harness.coordinator.reloadModel()
        harness.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(!harness.recorder.isRecording)
        #expect(harness.coordinator.privateDictation.isArmed)

        harness.settings.transcriptionSource = .onDevice
        harness.engine.prepareError = ProbeError()
        await harness.coordinator.reloadModel()
        #expect(harness.coordinator.preparedSource == nil)
        #expect(harness.coordinator.privateRefusal == .notOnDevice)
    }

    @Test("7. A private session clears lastDictation/lastTranscript and blocks corrections while armed")
    func lastDictationCleared() async throws {
        let harness = PrivateHarness()
        await harness.ready()
        harness.dictate()
        try await harness.settle()
        #expect(harness.coordinator.lastDictation != nil)
        #expect(harness.coordinator.lastTranscript != nil)

        harness.coordinator.armPrivateNextDictation()
        #expect(harness.coordinator.editingRefusal == PrivateDictationState.blocksEditingMessage)
        #expect(!harness.coordinator.beginCorrectionCapture(completion: { _ in }))
        #expect(harness.coordinator.refuseEditingIfPrivate())
        #expect(harness.coordinator.phase == .error(PrivateDictationState.blocksEditingMessage))

        harness.dictate(at: 10)
        try await harness.settle()
        #expect(harness.coordinator.lastDictation == nil)
        #expect(harness.coordinator.lastTranscript == nil)
        #expect(harness.coordinator.editingRefusal == nil)
    }

    @Test("8. A private dictation that did not paste lives only in memory, then expires")
    func clipboardFallback() async throws {
        let harness = PrivateHarness()
        harness.inserter.outcome = .noFocusedElement
        await harness.ready()
        harness.seedHistory()
        let before = harness.history.records

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await harness.settle()

        let text = try #require(harness.inserter.inserted.first)
        #expect(harness.coordinator.privateDictation.ephemeral.text == text)
        #expect(harness.coordinator.phase == .savedToClipboard(.nothingFocused))
        #expect(harness.history.records.map(\.outcome) == before.map(\.outcome))
        #expect(!harness.history.hasUnacknowledgedInsertion)

        harness.clock.now = harness.clock.now.addingTimeInterval(EphemeralDictation.defaultLifetime + 1)
        #expect(harness.coordinator.privateDictation.ephemeral.text == nil)
    }

    @Test("8b. An unconfirmed private paste also keeps the in-memory copy; the next start wipes it")
    func unconfirmedPasteAndWipeOnNextStart() async throws {
        let harness = PrivateHarness()
        harness.inserter.outcome = .insertedUnconfirmed
        await harness.ready()

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await harness.settle()
        #expect(harness.coordinator.privateDictation.ephemeral.hasText)
        #expect(harness.coordinator.phase == .savedToClipboard(.nothingFocused))
        #expect(!harness.coordinator.privateDictation.isArmed)

        harness.coordinator.handleHotkeyEdge(.down(at: 10))
        #expect(harness.recorder.isRecording)
        #expect(!harness.coordinator.privateDictation.ephemeral.hasText)
        #expect(harness.coordinator.cancelDictation())
    }

    @Test("Copy writes concealed + transient markers and ends the in-memory copy")
    func ephemeralCopy() {
        let clock = PrivateTestClock()
        let ephemeral = EphemeralDictation(now: { clock.now })
        ephemeral.set("My PIN hint is the blue door")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.plainsay.tests.private.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        #expect(ephemeral.copy(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "My PIN hint is the blue door")
        let types = pasteboard.types ?? []
        #expect(types.contains(ConcealedPasteboard.concealedType))
        #expect(types.contains(ConcealedPasteboard.transientType))
        #expect(ephemeral.text == nil)
        #expect(!ephemeral.copy(to: pasteboard))
    }

    @Test("9. Only a finished private dictation consumes the arm")
    func consumption() async throws {
        let inserted = PrivateHarness()
        await inserted.ready()
        inserted.coordinator.armPrivateNextDictation()
        inserted.dictate()
        try await inserted.settle()
        #expect(!inserted.coordinator.privateDictation.isArmed)

        let silence = PrivateHarness()
        silence.engine.transcript = ""
        await silence.ready()
        silence.coordinator.armPrivateNextDictation()
        silence.dictate()
        try await silence.settle()
        #expect(silence.coordinator.privateDictation.isArmed)
        #expect(silence.coordinator.phase == .error(PrivateDictationState.stillArmedMessage))

        let failure = PrivateHarness()
        failure.engine.error = ProbeError()
        await failure.ready()
        failure.coordinator.armPrivateNextDictation()
        failure.dictate()
        try await failure.settle()
        #expect(failure.coordinator.privateDictation.isArmed)
        #expect(failure.coordinator.phase == .error("probe failure \(PrivateDictationState.stillArmedMessage)"))
        #expect(failure.history.records.isEmpty)

        let cancelled = PrivateHarness()
        await cancelled.ready()
        cancelled.coordinator.armPrivateNextDictation()
        cancelled.coordinator.handleHotkeyEdge(.down(at: 0))
        #expect(cancelled.coordinator.sessionPolicy.privacy == .privateLocal)
        #expect(cancelled.coordinator.cancelDictation())
        try await cancelled.settle()
        #expect(cancelled.coordinator.privateDictation.isArmed)
        #expect(cancelled.coordinator.sessionPolicy == .standard)
    }

    @Test("A stray tap while armed writes no tooShort record, resets the policy and keeps the arm")
    func tooShortResetsPolicy() async throws {
        let harness = PrivateHarness()
        harness.recorder.duration = 0.1
        await harness.ready()
        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await harness.settle()

        #expect(harness.history.records.isEmpty)
        #expect(harness.coordinator.sessionPolicy == .standard)
        #expect(harness.coordinator.privateDictation.isArmed)
    }

    @Test("11. keepOnClipboard is forced off and writes are concealed only for the private session")
    func keepOnClipboardForcedOff() async throws {
        let harness = PrivateHarness()
        harness.settings.keepOnClipboard = true
        await harness.ready()

        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await harness.settle()
        harness.dictate(at: 10)
        try await harness.settle()

        #expect(harness.inserter.receivedKeepOnClipboard == [false, true])
        #expect(harness.inserter.receivedConcealed == [true, false])
    }

    @Test("12. The dictation after a private one is normal again")
    func returnToNormal() async throws {
        let harness = PrivateHarness()
        await harness.ready()
        harness.coordinator.armPrivateNextDictation()
        harness.dictate()
        try await harness.settle()
        #expect(harness.history.records.isEmpty)
        #expect(harness.cleanerBuilds.value == 0)

        harness.dictate(at: 10)
        try await harness.settle()
        #expect(harness.history.records.count == 1)
        #expect(harness.cleanerBuilds.value == 1)
        #expect(harness.engine.pendingFilesDuringTranscribe == [0, 1])
        #expect(harness.coordinator.lastDictation != nil)
    }

    @Test("Disarming drops the in-memory copy when no session is in flight")
    func disarmWipes() {
        let clock = PrivateTestClock()
        let state = PrivateDictationState(ephemeral: EphemeralDictation(now: { clock.now }))
        #expect(state.arm(unless: nil) == nil)
        state.ephemeral.set("text")
        state.disarm(sessionInFlight: true)
        #expect(!state.isArmed)
        #expect(state.ephemeral.hasText)
        state.disarm(sessionInFlight: false)
        #expect(!state.ephemeral.hasText)
        #expect(state.arm(unless: .modelNotReady) == .modelNotReady)
        #expect(!state.isArmed)
    }
}
