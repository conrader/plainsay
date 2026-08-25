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

    @Test("A clipboard fallback updates the original record and persists")
    func updateOutcomePersists() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-history-\(UUID().uuidString)")
        let history = TranscriptHistory(directory: dir)
        let original = record("copy me")
        history.add(original)

        history.updateOutcome(id: original.id, to: .insertionUnverified)

        #expect(history.records.count == 1)
        #expect(history.mostRecent?.outcome == .insertionUnverified)
        #expect(TranscriptHistory(directory: dir).mostRecent?.outcome == .insertionUnverified)
    }

    @Test("Acknowledging a paste warning survives relaunch and ignores newer empty events")
    func insertionAcknowledgementPersists() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-history-\(UUID().uuidString)")
        let history = TranscriptHistory(directory: dir)
        let failedPaste = TranscriptRecord(
            text: "recover me",
            rawText: "recover me",
            outcome: .insertionUnverified,
            durationSeconds: 1,
            targetApp: nil
        )
        history.add(failedPaste)
        history.add(TranscriptRecord(
            text: "",
            rawText: "",
            outcome: .tooShort,
            durationSeconds: 0.1,
            targetApp: nil
        ))

        #expect(history.hasUnacknowledgedInsertion)
        history.acknowledgeInsertionIssues()
        #expect(!history.hasUnacknowledgedInsertion)

        let relaunched = TranscriptHistory(directory: dir)
        #expect(!relaunched.hasUnacknowledgedInsertion)
        #expect(relaunched.records.first(where: { $0.id == failedPaste.id })?.outcome == .insertionUnverifiedAcknowledged)
    }

    @Test("Copying an unresolved dictation acknowledges its reminder")
    func copyingAcknowledgesInsertionIssue() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-history-\(UUID().uuidString)")
        let history = TranscriptHistory(directory: dir)
        let record = TranscriptRecord(
            text: "safe copy",
            rawText: "safe copy",
            outcome: .insertionUnverified,
            durationSeconds: 1,
            targetApp: nil
        )
        history.add(record)

        #expect(history.copyToClipboard(record))
        #expect(!history.hasUnacknowledgedInsertion)
        #expect(history.mostRecent?.outcome == .insertionUnverifiedAcknowledged)
    }
}

@Suite("Diagnostics command")
struct DiagnosticsCommandTests {
    /// The About tab copies this string for the user to paste into Terminal.
    /// If it ever stops naming the subsystem the loggers actually write to,
    /// it silently returns nothing and the diagnostics look like an app that
    /// records nothing at all.
    @Test("The copied command queries the subsystem the app logs to")
    func commandMatchesTheSubsystem() {
        #expect(Log.subsystem == "com.plainsay.dictation")
        #expect(Log.showCommand.contains("subsystem == \"\(Log.subsystem)\""))
        #expect(Log.showCommand.hasPrefix("log show"))
        // Without --info the pipeline's own records are filtered out, which
        // is precisely what someone runs this to read.
        #expect(Log.showCommand.contains("--info"))
    }
}

/// Retention and the off-switch — issue #28, carried over from the external
/// review in #1.
///
/// These are privacy guarantees, so they are asserted against the *file on
/// disk*, not against `records`. An in-memory array that looks empty while the
/// transcripts are still sitting in `history.json` is exactly the failure the
/// off-switch exists to prevent.
@Suite("History retention")
@MainActor
struct HistoryRetentionTests {
    private func makeDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-retention-\(UUID().uuidString)")
    }

    private func record(_ text: String, age: TimeInterval = 0) -> TranscriptRecord {
        TranscriptRecord(
            date: Date().addingTimeInterval(-age),
            text: text, rawText: text, outcome: .inserted,
            durationSeconds: 1, targetApp: "com.example.app"
        )
    }

    private func storedText(in directory: URL) -> String {
        let url = directory.appendingPathComponent("history.json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("Turning history off deletes what was already stored")
    func disablingPurgesDisk() {
        let dir = makeDirectory()
        let history = TranscriptHistory(directory: dir)
        history.add(record("my bank password is hunter2"))
        #expect(storedText(in: dir).contains("hunter2"), "precondition: it was written")

        history.setEnabled(false)

        // The whole point. A switch that only stops future writes tells the
        // user they have cleared something they have not.
        #expect(history.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path))
    }

    @Test("A disabled history records nothing, and stays empty across a relaunch")
    func disabledDoesNotRecord() {
        let dir = makeDirectory()
        let history = TranscriptHistory(directory: dir)
        history.setEnabled(false)
        history.add(record("said while off"))

        #expect(history.records.isEmpty)
        #expect(!storedText(in: dir).contains("said while off"))

        // Simulates the next launch with the preference still off.
        let relaunched = TranscriptHistory(isEnabled: false, directory: dir)
        #expect(relaunched.records.isEmpty)
    }

    @Test("Starting with history off clears a file left by an earlier run")
    func disabledAtLaunchPurgesLeftovers() {
        let dir = makeDirectory()
        let before = TranscriptHistory(directory: dir)
        before.add(record("from when it was on"))
        #expect(storedText(in: dir).contains("from when it was on"))

        _ = TranscriptHistory(isEnabled: false, directory: dir)

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path))
    }

    @Test("Records past the window are dropped, newer ones kept")
    func expiredRecordsAreDropped() {
        let dir = makeDirectory()
        let day: TimeInterval = 24 * 60 * 60
        let history = TranscriptHistory(maxAge: 30 * day, directory: dir)
        history.add(record("recent", age: day))
        history.add(record("ancient", age: 40 * day))

        let texts = history.records.map(\.text)
        #expect(texts.contains("recent"))
        #expect(!texts.contains("ancient"))
        #expect(!storedText(in: dir).contains("ancient"))
    }

    @Test("The window applies to records written before it existed")
    func windowAppliesRetroactively() {
        let dir = makeDirectory()
        let day: TimeInterval = 24 * 60 * 60

        // An install that had no age limit, holding something long expired.
        let unbounded = TranscriptHistory(maxAge: nil, directory: dir)
        unbounded.add(record("from last year", age: 400 * day))
        #expect(storedText(in: dir).contains("from last year"))

        // Updating must clean it out, not merely bound what comes next.
        let bounded = TranscriptHistory(maxAge: 30 * day, directory: dir)
        #expect(bounded.records.isEmpty)
        #expect(!storedText(in: dir).contains("from last year"))
    }

    @Test("Shortening the window prunes immediately, without waiting for a new dictation")
    func shorteningPrunesNow() {
        let dir = makeDirectory()
        let day: TimeInterval = 24 * 60 * 60
        let history = TranscriptHistory(maxAge: 365 * day, directory: dir)
        history.add(record("sixty days old", age: 60 * day))
        #expect(history.records.count == 1)

        history.applyPolicy(isEnabled: true, maxAge: 30 * day)

        #expect(history.records.isEmpty)
        #expect(!storedText(in: dir).contains("sixty days old"))
    }

    @Test("Clearing history removes the file, not just its contents")
    func clearRemovesFile() {
        let dir = makeDirectory()
        let history = TranscriptHistory(directory: dir)
        history.add(record("erase me"))

        history.clear()

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path))
    }
}
