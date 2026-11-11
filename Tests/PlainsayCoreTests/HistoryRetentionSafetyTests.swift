#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import PlainsayCore

/// Retention must never cost what it keeps, staging copies must not escape
/// deletion, and every failed delete or write must be visible in the state the
/// UI reads.
///
/// - Trimming a backup removes only records whose date reads as expired; a
///   truncated tail or an undated record stays byte for byte.
/// - A trim that cannot be written leaves the backup exactly as it was.
/// - `history.json.staging-*` files are swept by every launch, retention pass
///   and Clear.
/// - `deletionFailed`, `saveFailed`, `unsavedInMemory` and the Bool results
///   follow what is actually on disk, including after a failure is fixed.
///
/// Every test uses a fresh temporary directory, removed afterwards, and
/// asserts on the bytes on disk. Mode-based failures are skipped, visibly, as
/// root.
@Suite("History retention safety")
@MainActor
struct HistoryRetentionSafetyTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated private static let notRoot = getuid() != 0

    // MARK: - Fixtures

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            _ = chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func liveURL(_ dir: URL) -> URL { dir.appendingPathComponent("history.json") }

    private func record(_ text: String, age: TimeInterval = 0) -> TranscriptRecord {
        TranscriptRecord(date: fixedNow.addingTimeInterval(-age), text: text, rawText: text,
                         outcome: .inserted, durationSeconds: 1, targetApp: nil)
    }

    private func json(_ record: TranscriptRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    /// Undecodable by this build, but its date still reads.
    private func undecodable(_ text: String, age: TimeInterval) throws -> String {
        try json(record(text, age: age)).replacingOccurrences(of: "\"inserted\"", with: "\"fromTheFuture\"")
    }

    /// A record cut off mid-write: never closes, so no date can be read from it.
    private func truncated(_ text: String, age: TimeInterval) throws -> String {
        let whole = try json(record(text, age: age))
        return String(whole.prefix(upTo: whole.range(of: text)!.upperBound))
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func text(_ url: URL) -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }

    private func entries(_ dir: URL, _ marker: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("history.json" + marker) }.sorted().map { dir.appendingPathComponent($0) }
    }

    private func backups(_ dir: URL) -> [URL] { entries(dir, HistoryFile.backupMarker) }
    private func stages(_ dir: URL) -> [URL] { entries(dir, HistoryFile.stagingMarker) }

    private func history(
        _ dir: URL, maxAge: TimeInterval? = nil, isEnabled: Bool = true,
        backUp: ((URL, Data, Date) -> URL?)? = nil
    ) -> TranscriptHistory {
        TranscriptHistory(
            limit: 100, maxAge: maxAge, isEnabled: isEnabled, directory: dir,
            now: { [fixedNow] in fixedNow },
            backUp: backUp ?? { HistoryFile.backUp($0, original: $1, now: $2) }
        )
    }

    private func setMode(_ mode: mode_t, _ url: URL) { _ = chmod(url.path, mode) }

    // MARK: - 1. Trimming keeps every byte it cannot prove expired

    @Test("An expired record followed by a truncated recent tail: the tail survives in the backup")
    func expiredThenTruncatedTail() throws {
        try withDirectory { dir in
            let tail = try truncated("recenttail", age: 1 * day)
            try write("[\(try json(record("ancient", age: 400 * day))),\n\(tail)", to: liveURL(dir))

            let loaded = history(dir, maxAge: 30 * day)

            #expect(loaded.records.isEmpty)
            let backup = try #require(backups(dir).first, "the backup must not be deleted with the tail in it")
            #expect(text(backup) == "[\n" + tail)
            #expect(!text(liveURL(dir)).contains("ancient"))
            #expect(!loaded.deletionFailed)
        }
    }

    @Test("Recent, undated and truncated content all stay byte for byte; only expired records go")
    func onlyExpiredBytesAreCut() throws {
        try withDirectory { dir in
            let recent = try json(record("recentgood", age: 1 * day))
            let undated = #"{"id":"x","text":"nodate"}"#
            let tail = try truncated("recenttail", age: 2 * day)
            let original = """
                [\(try undecodable("oldbad", age: 400 * day)),
                \(recent), junk ,\(try json(record("oldgood", age: 90 * day))),\(undated),
                \(tail)
                """
            try write(original, to: liveURL(dir))

            let loaded = history(dir, maxAge: 30 * day)

            let kept = text(try #require(backups(dir).first))
            #expect(kept == "[\n\(recent), junk ,\(undated),\n\(tail)")
            #expect(!kept.contains("old"))
            #expect(loaded.records.map(\.text) == ["recentgood"])
            #expect(!text(liveURL(dir)).contains("old"))
            #expect(text(liveURL(dir)).contains("recentgood"))
        }
    }

    @Test("A backup left with only array punctuation is deleted, not kept as noise")
    func punctuationOnlyRemainderIsDeleted() throws {
        let cutoff = fixedNow.addingTimeInterval(-30 * day)
        let data = Data("\u{FEFF}[ \(try json(record("a", age: 400 * day))) ,\n \(try json(record("b", age: 400 * day))) ]".utf8)
        let trimmed = try #require(HistoryFile.trimmed(data, cutoff: cutoff))
        #expect(HistoryFile.isPunctuationOnly(trimmed))
        #expect(!HistoryFile.isPunctuationOnly(Data("[{\"t".utf8)))
        #expect(HistoryFile.trimmed(Data("[\(try json(record("new", age: 1 * day)))".utf8), cutoff: cutoff) == nil)
    }

    @Test("Undated bytes still go once the backup itself is older than the window")
    func undatedBytesGoWithAnOldBackup() throws {
        try withDirectory { dir in
            let name = "history.json" + HistoryFile.backupMarker + HistoryFile.timestamp(fixedNow.addingTimeInterval(-40 * day))
            try write("[" + (try truncated("undated", age: 1 * day)), to: dir.appendingPathComponent(name))

            let loaded = history(dir, maxAge: 30 * day)

            #expect(backups(dir).isEmpty)
            #expect(!loaded.deletionFailed)
        }
    }

    // MARK: - 2. A failed trim never deletes what it would have kept

    @Test("A trim that cannot be written leaves the backup untouched, is reported, and retries",
          .enabled(if: notRoot, "root ignores directory modes"))
    func failedTrimKeepsEverything() throws {
        try withDirectory { dir in
            let recentBad = try undecodable("recentbad", age: 2 * day)
            let tail = try truncated("recenttail", age: 1 * day)
            let original = "[\(try json(record("ancient", age: 400 * day))),\(recentBad),\(tail)"
            try write(original, to: liveURL(dir))
            let loaded = history(dir, maxAge: nil)
            let backup = try #require(backups(dir).first)
            #expect(text(backup) == original)

            setMode(0o500, dir)   // no stage can be created: the trim cannot be written
            #expect(!loaded.applyPolicy(isEnabled: true, maxAge: 30 * day), "a failed retention pass is a failed policy")

            #expect(text(backup) == original, "the recent records must still be on disk")
            #expect(text(liveURL(dir)) == original)
            #expect(loaded.deletionFailed)
            #expect(loaded.saveFailed && loaded.unsavedInMemory)
            #expect(stages(dir).isEmpty)

            setMode(0o700, dir)
            #expect(loaded.retryDeletion())
            #expect(!loaded.deletionFailed && !loaded.saveFailed)
            #expect(text(backup) == "[\(recentBad),\(tail)")
            #expect(!text(liveURL(dir)).contains("ancient"))
            #expect(stages(dir).isEmpty)
        }
    }

    @Test("A failed trim write keeps the backup even where deleting it would succeed")
    func failedTrimWriteNeverFallsBackToDelete() throws {
        try withDirectory { dir in
            let recentBad = try undecodable("recentbad", age: 2 * day)
            let original = "[\(try json(record("ancient", age: 400 * day))),\(recentBad),\(try truncated("tail", age: 1 * day))"
            let backup = dir.appendingPathComponent(
                "history.json" + HistoryFile.backupMarker + HistoryFile.timestamp(fixedNow))
            try write(original, to: backup)
            let cutoff = fixedNow.addingTimeInterval(-30 * day)

            let outcome = HistoryFile.applyRetention(toBackupsOf: liveURL(dir), cutoff: cutoff,
                                                     replace: { _, _ in false })

            #expect(outcome == .init(changed: true, failed: true))
            #expect(text(backup) == original, "a write that failed must not turn into a delete")

            let retried = HistoryFile.applyRetention(toBackupsOf: liveURL(dir), cutoff: cutoff)
            #expect(retried == .init(changed: true, failed: false))
            #expect(!text(backup).contains("ancient") && text(backup).contains("recentbad") && text(backup).contains("tail"))
        }
    }

    // MARK: - 3. Failure state follows the disk

    @Test("Retention emptying a damaged file it may not replace is reported, not silent")
    func protectedEmptySaveIsReported() throws {
        try withDirectory { dir in
            let original = "[\(try json(record("old", age: 400 * day))),\(try undecodable("bad", age: 400 * day))]"
            try write(original, to: liveURL(dir))
            let loaded = history(dir, maxAge: nil, backUp: { _, _, _ in nil })

            loaded.maxAge = 30 * day

            #expect(loaded.records.isEmpty)
            #expect(text(liveURL(dir)) == original, "no backup, so the file is still never replaced")
            #expect(loaded.saveFailed && loaded.unsavedInMemory)
            #expect(loaded.deletionFailed, "expired records are still on disk, and the user must hear it")
            #expect(!loaded.retryDeletion())
        }
    }

    @Test("A successful Clear clears a stale retention failure",
          .enabled(if: notRoot, "root ignores directory modes"))
    func purgeResetsRetentionFailure() throws {
        try withDirectory { dir in
            let loaded = history(dir, maxAge: nil)
            let old = dir.appendingPathComponent(
                "history.json" + HistoryFile.backupMarker + HistoryFile.timestamp(fixedNow.addingTimeInterval(-400 * day)))
            try write("old copy", to: old)
            setMode(0o500, dir)
            loaded.maxAge = 30 * day
            #expect(loaded.deletionFailed)

            setMode(0o700, dir)
            #expect(loaded.clear())
            #expect(!loaded.deletionFailed)
            #expect(!FileManager.default.fileExists(atPath: old.path))
        }
    }

    @Test("Retrying a failed Clear after new dictations removes the old copies and keeps the new ones",
          .enabled(if: notRoot, "root ignores directory modes"))
    func retryAfterFailedClearKeepsNewRecords() throws {
        try withDirectory { dir in
            try write("[\(try json(record("before clear"))),garbage", to: liveURL(dir))
            let loaded = history(dir)
            #expect(backups(dir).count == 1)
            setMode(0o500, dir)
            #expect(!loaded.clear())
            setMode(0o700, dir)

            loaded.add(record("after clear"))
            #expect(loaded.deletionFailed, "the backup of what was cleared is still there")
            #expect(!text(liveURL(dir)).contains("before clear"), "the live file is not read back and merged")

            #expect(loaded.retryDeletion())
            #expect(!loaded.deletionFailed)
            #expect(backups(dir).isEmpty)
            #expect(history(dir).records.map(\.text) == ["after clear"])
        }
    }

    @Test("What a failed Clear left in an unreadable file is never merged back when it reads again",
          .enabled(if: notRoot, "root ignores file modes"))
    func failedClearOfProtectedFileIsNotResurrected() throws {
        try withDirectory { dir in
            try write("[\(try json(record("cleared secret")))]", to: liveURL(dir))
            setMode(0o000, liveURL(dir))
            let loaded = history(dir)
            #expect(loaded.diskState == .protected)
            setMode(0o500, dir)
            #expect(!loaded.clear())

            setMode(0o700, dir)
            setMode(0o600, liveURL(dir))
            loaded.add(record("new"))

            #expect(loaded.records.map(\.text) == ["new"])
            #expect(!text(liveURL(dir)).contains("cleared secret"))
        }
    }

    @Test("With history off, retrying is the whole purge again",
          .enabled(if: notRoot, "root ignores directory modes"))
    func retryWhileOffPurges() throws {
        try withDirectory { dir in
            let loaded = history(dir)
            loaded.add(record("secret"))
            setMode(0o500, dir)
            #expect(!loaded.setEnabled(false))
            #expect(!loaded.retryDeletion())

            setMode(0o700, dir)
            #expect(loaded.retryDeletion())
            #expect(!loaded.deletionFailed)
            #expect(!FileManager.default.fileExists(atPath: liveURL(dir).path))
        }
    }

    @Test("A write failure leaves the records only in memory, and says so until a save lands",
          .enabled(if: notRoot, "root ignores directory modes"))
    func unsavedInMemoryFollowsTheDisk() throws {
        try withDirectory { dir in
            let loaded = history(dir)
            loaded.add(record("first"))
            #expect(!loaded.unsavedInMemory)
            setMode(0o500, dir)
            loaded.add(record("second"))
            #expect(loaded.saveFailed && loaded.unsavedInMemory)
            #expect(stages(dir).isEmpty)

            setMode(0o700, dir)
            loaded.add(record("third"))
            #expect(!loaded.saveFailed && !loaded.unsavedInMemory)
        }
    }

    // MARK: - 5. Staging copies never escape deletion

    @Test("A stage abandoned by a crash is swept at launch, even with no age window")
    func abandonedStageSweptAtLaunch() throws {
        try withDirectory { dir in
            let stage = dir.appendingPathComponent("history.json" + HistoryFile.stagingMarker + UUID().uuidString)
            try write("[\(try json(record("half-written secret")))]", to: stage)

            let loaded = history(dir, maxAge: nil)

            #expect(stages(dir).isEmpty)
            #expect(loaded.records.isEmpty, "a stage is never adopted as history")
            #expect(!loaded.deletionFailed)
        }
    }

    @Test("Clear and the off switch remove abandoned stages")
    func purgeRemovesStages() throws {
        try withDirectory { dir in
            let loaded = history(dir)
            loaded.add(record("kept"))
            let stage = dir.appendingPathComponent("history.json" + HistoryFile.stagingMarker + "crash")
            try write("secret", to: stage)
            #expect(loaded.clear())
            #expect(stages(dir).isEmpty)

            try write("secret", to: stage)
            #expect(loaded.setEnabled(false))
            #expect(stages(dir).isEmpty)
        }
    }

    @Test("A stage that cannot be removed is reported",
          .enabled(if: notRoot, "root ignores directory modes"))
    func unremovableStageIsReported() throws {
        try withDirectory { dir in
            let loaded = history(dir, maxAge: nil)   // init makes the directory 0700
            try write("secret", to: dir.appendingPathComponent("history.json" + HistoryFile.stagingMarker + "crash"))
            setMode(0o500, dir)
            loaded.maxAge = 30 * day
            #expect(loaded.deletionFailed)
            #expect(stages(dir).count == 1)
            setMode(0o700, dir)
            #expect(loaded.retryDeletion())
            #expect(stages(dir).isEmpty)
        }
    }

    @Test("Saving and trimming leave no stage behind, and a failed rename removes its stage")
    func replaceLeavesNoStage() throws {
        try withDirectory { dir in
            let loaded = history(dir, maxAge: 30 * day)
            loaded.add(record("one"))
            #expect(stages(dir).isEmpty)
            #expect(history(dir).records.map(\.text) == ["one"])

            // Renaming a file over a non-empty directory fails.
            let blocked = dir.appendingPathComponent("blocked")
            try FileManager.default.createDirectory(at: blocked.appendingPathComponent("inside"), withIntermediateDirectories: true)
            #expect(!HistoryFile.replace(blocked, with: Data("secret".utf8)))
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!names.contains { $0.contains(HistoryFile.stagingMarker) })
        }
    }

    @Test("A trimmed backup is owner-only")
    func trimmedBackupIsPrivate() throws {
        try withDirectory { dir in
            try write("[\(try json(record("ancient", age: 400 * day))),\(try truncated("recent", age: 1 * day))", to: liveURL(dir))
            _ = history(dir, maxAge: 30 * day)
            let backup = try #require(backups(dir).first)
            let mode = try #require((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue)
            #expect(mode == 0o600)
            #expect(!text(backup).contains("ancient"))
        }
    }
}
