import Foundation
import Testing
@testable import PlainsayCore

@Suite("Pending audio retention")
struct PendingAudioRetentionTests {
    private func makeStore() -> (store: PendingAudioStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-pending-retention-\(UUID().uuidString)")
        return (PendingAudioStore(directory: directory), directory)
    }

    @Test("prune discards recordings older than the age cap")
    func prunesByAge() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(store.save([0.1, 0.2, 0.3]))

        // Backdate the file well past the age cap.
        let old = Date().addingTimeInterval(-(PendingAudioStore.maxAge + 3600))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)

        store.prune()
        #expect(store.recoverable().isEmpty)
    }

    @Test("prune keeps only the newest recordings past the count cap")
    func prunesByCount() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = PendingAudioStore.maxCount + 5
        var urls: [URL] = []
        for index in 0..<total {
            let url = try #require(store.save([0.1, 0.2]))
            let modified = Date().addingTimeInterval(Double(index - total) * 60)
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: url.path
            )
            urls.append(url)
        }

        store.prune()
        let expected = urls.suffix(PendingAudioStore.maxCount).map(\.lastPathComponent)
        let remaining = store.recoverable().map(\.lastPathComponent)
        #expect(remaining == expected)
    }

    @Test("purgeAll removes every staged recording")
    func purgeRemovesEverything() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<3 { store.save([0.1]) }
        #expect(!store.recoverable().isEmpty)

        store.purgeAll()
        #expect(store.recoverable().isEmpty)
    }

    @Test("a fresh recording within the caps survives prune")
    func keepsFreshRecording() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(store.save([0.1, 0.2]))
        store.prune()
        #expect(store.recoverable().map(\.lastPathComponent) == [url.lastPathComponent])
    }

    @Test("clearing stored dictations removes transcripts and staged audio")
    @MainActor
    func clearAllStoredDictationsPurgesBothStores() throws {
        let (store, pendingDirectory) = makeStore()
        let historyDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-retention-history-\(UUID().uuidString)")
        let defaultsName = "plainsay.retention-clear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: pendingDirectory)
            try? FileManager.default.removeItem(at: historyDirectory)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let history = TranscriptHistory(directory: historyDirectory)
        history.add(TranscriptRecord(
            text: "private dictation",
            rawText: "private dictation",
            outcome: .inserted,
            durationSeconds: 1,
            targetApp: nil
        ))
        _ = try #require(store.save([0.1, 0.2]))

        let engine = FakeEngine()
        let cleaner = FakeCleaner()
        let coordinator = DictationCoordinator(
            settings: PlainsaySettings(defaults: defaults),
            history: history,
            pendingAudio: store,
            recorder: FakeRecorder(),
            inserter: FakeInserter(),
            makeEngine: { _, _, _ in engine },
            makeCleaner: { _ in cleaner },
            microphoneAuthorized: { true },
            usesInjectedEngine: true
        )

        coordinator.clearAllStoredDictations()

        #expect(history.records.isEmpty)
        #expect(store.recoverable().isEmpty)
    }
}
