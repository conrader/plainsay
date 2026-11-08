import AppKit
import Foundation
import Testing
@testable import PlainsayCore

// remember-correction v1 in the pipeline (SPEC.fixed.md §4 tests 19–22) and
// in Settings (§2.6). Same fakes as PipelineTests and DictationCorrectionTests.
// Needs the full coordinator, so it runs on the Mac only.

@MainActor
private struct RulesHarness {
    let settings: PlainsaySettings
    let recorder = FakeRecorder()
    let engine = FakeEngine()
    let cleaner = FakeCleaner()
    let inserter = FakeInserter()
    let history: TranscriptHistory
    let pending: PendingAudioStore
    let coordinator: DictationCoordinator

    init(rules: [ReplacementRule], polishing: Bool) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-pipeline-\(UUID())")
        history = TranscriptHistory(directory: root.appendingPathComponent("history"))
        pending = PendingAudioStore(directory: root.appendingPathComponent("audio"))
        let settings = PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.rules.\(UUID().uuidString)")!)
        settings.dictionary = TermDictionary(terms: [])
        settings.playFeedbackSounds = false
        settings.livePreviewEnabled = false
        settings.cleanupEnabled = polishing
        settings.replacementRules = ReplacementRuleSet(rules: rules)
        self.settings = settings
        let engine = self.engine
        let cleaner = self.cleaner
        coordinator = DictationCoordinator(settings: settings, history: history, pendingAudio: pending,
            recorder: recorder, inserter: inserter, makeEngine: { _, _, _ in engine },
            makeCleaner: { _ in cleaner }, microphoneAuthorized: { true },
            capturePasteTarget: { FakePasteTarget() }, usesInjectedEngine: true)
    }

    func dictate() async throws {
        let before = inserter.inserted.count
        coordinator.handleHotkeyEdge(.down(at: 0))
        coordinator.handleHotkeyEdge(.up(at: 1))
        try await waitUntil { inserter.inserted.count > before && !coordinator.phase.isBusy }
    }

    func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

private let jason = ReplacementRule(from: "jason", to: "JSON")

@Suite("Replacement rules in the pipeline", .serialized)
@MainActor
struct ReplacementRulesPipelineTests {
    @Test("19. Polishing off: the rule reaches the paste and History text; rawText keeps the transcript")
    func insertedAndHistory() async throws {
        let h = RulesHarness(rules: [jason], polishing: false)
        h.engine.transcript = "open the jason file"
        await h.coordinator.reloadModel()
        try await h.dictate()
        #expect(h.inserter.inserted == ["open the JSON file"])
        #expect(h.history.records.first?.text == "open the JSON file")
        #expect(h.history.records.first?.rawText == "open the jason file")
        #expect(h.coordinator.lastDictation?.text == "open the JSON file")
    }

    @Test("20. Rules apply to the cleaned output; the cleaner received the pre-rule text")
    func afterPolishing() async throws {
        let h = RulesHarness(rules: [jason], polishing: true)
        h.engine.transcript = "um open the jason file"
        h.cleaner.output = "OPEN THE JASON FILE."
        await h.coordinator.reloadModel()
        try await h.dictate()
        #expect(h.cleaner.received == "um open the jason file")
        #expect(h.inserter.inserted == ["OPEN THE JSON FILE."])
    }

    @Test("20. A Polishing failure still gets the rules on the raw transcript")
    func afterPolishingFailure() async throws {
        let h = RulesHarness(rules: [jason], polishing: true)
        h.engine.transcript = "open the jason file"
        h.cleaner.error = CleanupError.emptyResponse
        await h.coordinator.reloadModel()
        try await h.dictate()
        #expect(h.inserter.inserted == ["open the JSON file"])
    }

    @Test("8. Master switch off or rule disabled: text unchanged")
    func switchedOff() async throws {
        let h = RulesHarness(rules: [jason], polishing: false)
        h.settings.replacementRules.isEnabled = false
        h.engine.transcript = "open the jason file"
        await h.coordinator.reloadModel()
        try await h.dictate()
        #expect(h.inserter.inserted == ["open the jason file"])

        h.settings.replacementRules.isEnabled = true
        h.settings.replacementRules.setEnabled(false, id: jason.id)
        try await h.dictate()
        #expect(h.inserter.inserted.last == "open the jason file")
    }

    @Test("21. The correction-command transcript is returned without rules")
    func correctionCapture() async throws {
        let h = RulesHarness(rules: [jason], polishing: false)
        h.engine.transcript = "Send the jason file."
        await h.coordinator.reloadModel()
        try await h.dictate()
        h.engine.transcript = "change jason to JSON"
        var result: Result<String, Error>?
        #expect(h.coordinator.beginCorrectionCapture { result = $0 })
        h.coordinator.finishCorrectionCapture()
        try await h.waitUntil { result != nil }
        #expect(try result?.get() == "change jason to JSON")
    }

    @Test("22. Recovered audio gets the rules in History text, not in rawText")
    func recovery() async throws {
        let h = RulesHarness(rules: [jason], polishing: true)
        h.engine.transcript = "open the jason file"
        h.cleaner.output = "Open the jason file."
        _ = try #require(h.pending.save([Float](repeating: 0.1, count: Int(whisperSampleRate))))
        await h.coordinator.reloadModel()
        await h.coordinator.recoverInterruptedAudio()
        let record = try #require(h.history.records.first)
        #expect(record.outcome == .recovered)
        #expect(record.text == "Open the JSON file.")
        #expect(record.rawText == "open the jason file")
        #expect(h.inserter.inserted.isEmpty)
    }
}

@Suite("Replacement rules in Settings")
@MainActor
struct ReplacementRulesSettingsTests {
    @Test("2.6. Default is an empty, enabled set; rules persist and reload; a bad rule drops alone")
    func persistence() throws {
        let name = "plainsay.rules.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let fresh = PlainsaySettings(defaults: defaults)
        #expect(fresh.replacementRules == ReplacementRuleSet())
        #expect(fresh.replacementRules.isEnabled)

        fresh.replacementRules.upsert(ReplacementRule(from: "Kowalsky", to: "Kowalski"))
        #expect(PlainsaySettings(defaults: defaults).replacementRules.rules.map(\.to) == ["Kowalski"])

        let json = #"{"isEnabled":false,"rules":[{"from":"jason","to":"JSON"},{"from":42},{"from":"x"}]}"#
        defaults.set(Data(json.utf8), forKey: "replacementRules")
        let reloaded = PlainsaySettings(defaults: defaults).replacementRules
        #expect(!reloaded.isEnabled)
        #expect(reloaded.rules.map(\.from) == ["jason"])
        defaults.removePersistentDomain(forName: name)
    }
}
