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

    @Test("Transcripts on disk are readable only by their owner, and skipped by backups")
    func historyFileIsPrivate() throws {
        // Every one of these is a verbatim record of something the user said.
        // They used to land at the default 0644 in a 0755 directory, and were
        // copied into Time Machine — raised in an external review (#1).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-history-\(UUID().uuidString)")
        let history = TranscriptHistory(directory: dir)
        history.add(record("something private"))

        let fileURL = dir.appendingPathComponent("history.json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        func mode(_ url: URL) throws -> Int {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }

        // The file check is the one that matters: `Data.write(options: .atomic)`
        // renames a temporary file over the destination, so a mode set before
        // the write would be silently replaced by the temporary file's own.
        #expect(try mode(fileURL) == 0o600)
        #expect(try mode(dir) == 0o700)

        let excluded = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(excluded.isExcludedFromBackup == true)
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
