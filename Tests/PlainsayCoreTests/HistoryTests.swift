import Foundation
import Testing
@testable import PlainsayCore

@Suite("Transcript history")
@MainActor
struct TranscriptHistoryTests {
    private func makeHistory(limit: Int = 100) -> TranscriptHistory {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-history-\(UUID().uuidString)")
        return TranscriptHistory(limit: limit, directory: dir)
    }

    private func record(_ text: String) -> TranscriptRecord {
        TranscriptRecord(
            text: text, rawText: text, outcome: .inserted,
            durationSeconds: 1, targetApp: "com.example.app"
        )
    }

    @Test("Newest dictation comes first")
    func newestFirst() {
        let history = makeHistory()
        history.add(record("first"))
        history.add(record("second"))

        #expect(history.records.map(\.text) == ["second", "first"])
        #expect(history.mostRecent?.text == "second")
    }

    @Test("Old entries fall off once the limit is reached")
    func respectsLimit() {
        let history = makeHistory(limit: 3)
        for i in 1...5 { history.add(record("entry \(i)")) }

        #expect(history.records.count == 3)
        #expect(history.records.map(\.text) == ["entry 5", "entry 4", "entry 3"])
    }

    @Test("History survives a relaunch")
    func persistsToDisk() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-history-\(UUID().uuidString)")

        let first = TranscriptHistory(directory: dir)
        first.add(record("remember me"))

        // A second instance is what a relaunch looks like.
        let reopened = TranscriptHistory(directory: dir)
        #expect(reopened.records.map(\.text) == ["remember me"])
    }

    @Test("Clearing empties it on disk too")
    func clearPersists() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-history-\(UUID().uuidString)")

        let history = TranscriptHistory(directory: dir)
        history.add(record("temporary"))
        history.clear()

        #expect(TranscriptHistory(directory: dir).records.isEmpty)
    }

    @Test("The raw transcript is kept alongside the cleaned one")
    func keepsRawText() {
        let history = makeHistory()
        history.add(TranscriptRecord(
            text: "I'll be there Tuesday.",
            rawText: "um i'll uh be there tuesday",
            outcome: .inserted, durationSeconds: 2, targetApp: nil
        ))

        // A cleanup that mangles the meaning must not destroy the original.
        #expect(history.mostRecent?.rawText == "um i'll uh be there tuesday")
    }
}
