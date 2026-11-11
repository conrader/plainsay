#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import PlainsayCore

@Suite("History recovery and Vocabulary retirement")
@MainActor
struct HistoryRuleRetirementTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsay-history-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            _ = chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func record(_ text: String) -> TranscriptRecord {
        TranscriptRecord(text: text, rawText: text, outcome: .inserted, durationSeconds: 1, targetApp: nil)
    }

    private func write(_ records: [TranscriptRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: url)
    }

    private func retiredRules(overflow: Bool = false) -> ReplacementRuleSet {
        let rule = ReplacementRule(from: "lumen tar", to: "Lumenta Studio")
        var rules = ReplacementRuleSet(rules: [rule])
        rules.remove(id: rule.id)
        if overflow {
            for i in 0..<ReplacementRuleSet.retiredLimit { rules.retire("Term\(i)x", now: Date()) }
        }
        return rules
    }

    private func proposals(_ history: TranscriptHistory, _ rules: ReplacementRuleSet) -> Set<String> {
        Set(rules.excludingTargets(from: DictionaryProposer.propose(from: history.records)).map(\.term))
    }

    @Test("Late History recovery never reopens a retired target or settles overflow too early", arguments: [false, true])
    func lateRecovery(overflow: Bool) throws {
        try withDirectory { dir in
            let live = dir.appendingPathComponent("history.json")
            // An unreadable live path without relying on permissions/root.
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
            let history = TranscriptHistory(maxAge: nil, directory: dir)
            #expect(history.records.isEmpty && history.hasUnresolvedDiskContents)
            var rules = retiredRules(overflow: overflow)
            let before = rules
            let index = RetiredTargetHistoryIndex()
            // Exactly the live-store API Vocabulary uses when it opens.
            rules = rules.pruningRetiredTargets(history: history, workInFlight: false, index: index)
            #expect(rules == before)
            #expect(index.folds == 0)

            try FileManager.default.removeItem(at: live)
            try write([record("We ship Lumenta Studio."), record("Ask about Lumenta Studio.")], to: live)
            history.add(record("new dictation")) // mayReplaceFile adopts the previously unreadable records
            #expect(!history.hasUnresolvedDiskContents)
            #expect(history.records.count == 3)
            #expect(proposals(history, ReplacementRuleSet()).contains("Lumenta"))
            rules = rules.pruningRetiredTargets(history: history, workInFlight: false, index: index)
            #expect(!proposals(history, rules).contains("Lumenta"))
            #expect(!proposals(history, rules).contains("Studio"))
            if overflow { #expect(rules.retiredOverflow != nil) }

            #expect(history.clear())
            #expect(!history.hasUnresolvedDiskContents)
            rules = rules.pruningRetiredTargets(history: history, workInFlight: false, index: index)
            #expect(rules.retiredTargets.isEmpty && rules.retiredOverflow == nil)
        }
    }

    @Test("Failed Clear cannot let Vocabulary forget a target that reappears on relaunch",
          .enabled(if: getuid() != 0, "root ignores directory modes"))
    func failedClearThenRelaunch() throws {
        try withDirectory { dir in
            let history = TranscriptHistory(maxAge: nil, directory: dir)
            history.add(record("We ship Lumenta Studio."))
            history.add(record("Ask about Lumenta Studio."))
            var rules = retiredRules()
            #expect(chmod(dir.path, 0o500) == 0)
            #expect(!history.clear())
            #expect(history.records.isEmpty && history.hasUnresolvedDiskContents)
            rules = rules.pruningRetiredTargets(history: history, workInFlight: false)
            #expect(rules.retiredTargets.count == 1)
            // Simulate the settings persisted by Vocabulary before quitting.
            let persisted = try JSONEncoder().encode(rules)

            #expect(chmod(dir.path, 0o700) == 0)
            let reopened = TranscriptHistory(maxAge: nil, directory: dir)
            let reloaded = try JSONDecoder().decode(ReplacementRuleSet.self, from: persisted)
                .pruningRetiredTargets(history: reopened, workInFlight: false)
            #expect(reopened.records.count == 2)
            #expect(proposals(reopened, ReplacementRuleSet()).contains("Lumenta"))
            #expect(!proposals(reopened, reloaded).contains("Lumenta"))
            #expect(!proposals(reopened, reloaded).contains("Studio"))

            // Resolve the failure on the original object with no record-ID
            // change: the UI's disk-state trigger must allow pruning again.
            #expect(history.retryDeletion())
            #expect(history.records.isEmpty && !history.hasUnresolvedDiskContents)
            #expect(rules.pruningRetiredTargets(history: history, workInFlight: false).retiredTargets.isEmpty)
        }
    }

    @Test("Vocabulary passes the live History store and retries when disk uncertainty resolves")
    func vocabularyWiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/PlainsayApp/VocabularySettings.swift"),
                                encoding: .utf8)
        #expect(source.contains("history: coordinator.history, workInFlight: coordinator.mayStillWriteHistory"))
        #expect(source.contains("unresolvedDiskContents: coordinator.history.hasUnresolvedDiskContents"))
    }
}
