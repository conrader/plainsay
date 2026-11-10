#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import PlainsayCore

/// What happens to damage backups and failed disk operations.
///
/// The `.damaged-*` copies hold the same transcripts as `history.json`, so
/// Clear, the off switch and the age window have to reach them; a copy that is
/// trusted to hold the only readable original must really be independent and
/// private; a file that reads again mid-run must be merged, not replaced; and a
/// delete or write that fails must say so. Every test uses a fresh temporary
/// directory and asserts on the bytes on disk.
///
/// Tests that depend on file modes are skipped, visibly, when run as root.
@Suite("History privacy and failures")
@MainActor
struct HistoryPrivacyTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
    nonisolated private static let notRoot = getuid() != 0

    // MARK: - Fixtures

    private func makeDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-privacy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func historyURL(_ dir: URL) -> URL { dir.appendingPathComponent("history.json") }

    private func record(_ text: String, age: TimeInterval = 0, id: UUID = UUID()) -> TranscriptRecord {
        TranscriptRecord(
            id: id, date: fixedNow.addingTimeInterval(-age),
            text: text, rawText: text, outcome: .inserted,
            durationSeconds: 1, targetApp: "com.example.app"
        )
    }

    private func json(_ record: TranscriptRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    /// Undecodable by this build (unknown outcome), but its date still reads.
    private func undecodable(_ text: String, age: TimeInterval = 0) throws -> String {
        try json(record(text, age: age))
            .replacingOccurrences(of: "\"inserted\"", with: "\"fromTheFuture\"")
    }

    @discardableResult
    private func write(_ text: String, to url: URL) throws -> Data {
        let data = Data(text.utf8)
        try data.write(to: url)
        return data
    }

    private func backups(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("history.json" + HistoryFile.backupMarker) }
            .sorted().map { dir.appendingPathComponent($0) }
    }

    private func backupName(daysBeforeNow days: Double) -> String {
        "history.json" + HistoryFile.backupMarker + HistoryFile.timestamp(fixedNow.addingTimeInterval(-days * day))
    }

    private func text(_ url: URL) -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(
            (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        )
    }

    private func setMode(_ mode: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    private func history(
        _ dir: URL, maxAge: TimeInterval? = nil, isEnabled: Bool = true
    ) -> TranscriptHistory {
        TranscriptHistory(
            limit: 100, maxAge: maxAge, isEnabled: isEnabled, directory: dir,
            now: { [fixedNow] in fixedNow },
            backUp: { HistoryFile.backUp($0, original: $1, now: $2) }
        )
    }

    // MARK: - 1. Deletion and retention reach the backups

    @Test("Turning history off deletes the damage backups too")
    func disablingDeletesBackups() throws {
        let dir = makeDirectory()
        try write("garbage", to: historyURL(dir))
        let loaded = history(dir)
        #expect(backups(in: dir).count == 1)

        #expect(loaded.setEnabled(false))

        #expect(backups(in: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: historyURL(dir).path))
    }

    @Test("Launching with history off deletes leftover backups of any age")
    func disabledLaunchDeletesBackups() throws {
        let dir = makeDirectory()
        try write("garbage", to: historyURL(dir))
        try write("an older copy", to: dir.appendingPathComponent(backupName(daysBeforeNow: 3)))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(backupName(daysBeforeNow: 2)), withDestinationURL: historyURL(dir)
        )

        _ = history(dir, isEnabled: false)

        #expect(backups(in: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: historyURL(dir).path))
    }

    @Test("The coordinator's launch order — load enabled, then apply 'off' — leaves no backup")
    func launchThenPolicyOff() throws {
        let dir = makeDirectory()
        try write("[\(try undecodable("secret"))]", to: historyURL(dir))
        let loaded = history(dir)            // the default argument starts enabled
        #expect(backups(in: dir).count == 1)

        #expect(loaded.applyPolicy(isEnabled: false, maxAge: 30 * day))

        #expect(backups(in: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: historyURL(dir).path))
    }

    @Test("A backup made before the age cutoff is deleted; a newer one stays")
    func oldBackupExpires() throws {
        let dir = makeDirectory()
        try write("[\(try json(record("fine")))]", to: historyURL(dir))
        let old = dir.appendingPathComponent(backupName(daysBeforeNow: 40))
        let recent = dir.appendingPathComponent(backupName(daysBeforeNow: 10))
        try write("no date in here", to: old)
        try write("no date in here either", to: recent)

        _ = history(dir, maxAge: 30 * day)

        #expect(backups(in: dir) == [recent])
    }

    @Test("Expired records are cut from a backup; the unexpired rest is kept, live file rewritten")
    func expiredRecordsCutFromBackup() throws {
        let dir = makeDirectory()
        let fresh = record("freshgood", age: 1 * day)
        try write("""
            [\(try json(fresh)),\(try undecodable("recentbad", age: 2 * day)),\
            \(try json(record("ancientgood", age: 400 * day))),\(try undecodable("ancientbad", age: 400 * day))]
            """, to: historyURL(dir))

        let loaded = history(dir, maxAge: 30 * day)

        #expect(loaded.records.map(\.id) == [fresh.id])
        let backup = try #require(backups(in: dir).first)
        #expect(backups(in: dir).count == 1)
        #expect(text(backup).contains("recentbad"), "an unexpired record we cannot decode must survive")
        #expect(text(backup).contains("freshgood"))
        #expect(!text(backup).contains("ancient"))
        #expect(try mode(backup) == 0o600)
        // The live file no longer holds the expired bytes either.
        #expect(!text(historyURL(dir)).contains("ancient"))
        #expect(history(dir).records.map(\.id) == [fresh.id])
    }

    @Test("A backup holding nothing unexpired goes, and the live file is emptied")
    func fullyExpiredBackupDeleted() throws {
        let dir = makeDirectory()
        try write("[\(try json(record("ancientgood", age: 400 * day))),\(try undecodable("ancientbad", age: 400 * day))]",
                  to: historyURL(dir))

        let loaded = history(dir, maxAge: 30 * day)

        #expect(loaded.records.isEmpty)
        #expect(backups(in: dir).isEmpty)
        #expect(!text(historyURL(dir)).contains("ancient"))
    }

    @Test("Shortening the window reaches backups immediately; no window keeps them")
    func shorteningWindowReachesBackups() throws {
        let dir = makeDirectory()
        try write("[\(try undecodable("ancientbad", age: 400 * day))]", to: historyURL(dir))
        let loaded = history(dir, maxAge: nil)
        #expect(backups(in: dir).count == 1)

        loaded.maxAge = 30 * day

        #expect(backups(in: dir).isEmpty)
        #expect(!text(historyURL(dir)).contains("ancient"))
    }

    // MARK: - 2. A reused backup must be independent and private

    @Test("A symlink to the live file is not accepted as its backup")
    func symlinkToLiveIsNotABackup() throws {
        let dir = makeDirectory()
        let original = try write("garbage", to: historyURL(dir))
        let alias = dir.appendingPathComponent(backupName(daysBeforeNow: 1))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: historyURL(dir))

        let loaded = history(dir)
        #expect(loaded.diskState == .backedUp)
        loaded.add(record("replaces the live file"))

        let real = backups(in: dir).filter { !isSymlink($0) }
        #expect(real.count == 1)
        #expect(try real.map { try Data(contentsOf: $0) } == [original])
        #expect(text(alias).contains("replaces the live file"), "the alias followed the live file, as expected")
    }

    @Test("A hard link to the live file is not accepted as its backup")
    func hardLinkToLiveIsNotABackup() throws {
        let dir = makeDirectory()
        let original = try write("garbage", to: historyURL(dir))
        let alias = dir.appendingPathComponent(backupName(daysBeforeNow: 1))
        try FileManager.default.linkItem(at: historyURL(dir), to: alias)

        history(dir).add(record("new"))

        let independent = backups(in: dir).filter { $0 != alias }
        #expect(try independent.map { try Data(contentsOf: $0) } == [original])
    }

    @Test("A matching backup left world-readable is made owner-only before it is reused")
    func permissiveBackupIsTightened() throws {
        let dir = makeDirectory()
        let original = try write("garbage", to: historyURL(dir))
        let existing = dir.appendingPathComponent(backupName(daysBeforeNow: 1))
        try original.write(to: existing)
        try setMode(0o644, existing)

        let loaded = history(dir)

        #expect(loaded.diskState == .backedUp)
        #expect(backups(in: dir) == [existing], "identical and fixable: reused, not duplicated")
        #expect(try mode(existing) == 0o600)
    }

    @Test("A live file that is itself a link still gets a regular, private copy")
    func linkedLiveFileGetsRegularBackup() throws {
        let dir = makeDirectory()
        let elsewhere = dir.appendingPathComponent("elsewhere.json")
        let original = try write("garbage", to: elsewhere)
        try FileManager.default.createSymbolicLink(at: historyURL(dir), withDestinationURL: elsewhere)

        _ = history(dir)

        let copy = try #require(backups(in: dir).first)
        #expect(!isSymlink(copy))
        #expect(try Data(contentsOf: copy) == original)
        #expect(try mode(copy) == 0o600)
    }

    // MARK: - 3. A file that reads again is merged, not replaced

    @Test("A valid file unreadable at launch is merged in once it reads",
          .enabled(if: notRoot, "root ignores file modes"))
    func unreadableThenReadableMerges() throws {
        let dir = makeDirectory()
        let a = record("from disk", age: day)
        try write("[\(try json(a))]", to: historyURL(dir))
        try setMode(0o000, historyURL(dir))
        defer { try? setMode(0o600, historyURL(dir)) }

        let loaded = history(dir)
        #expect(loaded.diskState == .protected)
        #expect(loaded.records.isEmpty)

        try setMode(0o600, historyURL(dir))
        loaded.add(record("this run"))

        #expect(!loaded.saveFailed)
        #expect(loaded.diskState == .owned)
        #expect(history(dir).records.map(\.text) == ["this run", "from disk"])
        #expect(backups(in: dir).isEmpty, "nothing undecodable, so nothing needs a copy")
    }

    @Test("The merge keeps this run's version of a record and applies the age window",
          .enabled(if: notRoot, "root ignores file modes"))
    func mergeRespectsUpdatesAndRetention() throws {
        let dir = makeDirectory()
        let shared = UUID()
        try write("""
            [\(try json(record("disk version", age: day, id: shared))),\(try json(record("kept from disk", age: 2 * day))),\
            \(try json(record("expired", age: 400 * day)))]
            """, to: historyURL(dir))
        try setMode(0o000, historyURL(dir))
        defer { try? setMode(0o600, historyURL(dir)) }

        let loaded = history(dir, maxAge: 30 * day)
        loaded.add(record("this run's version", id: shared))
        #expect(loaded.saveFailed)

        try setMode(0o600, historyURL(dir))
        loaded.add(record("later"))

        let stored = history(dir).records.map(\.text)
        #expect(stored == ["later", "this run's version", "kept from disk"])
        #expect(!text(historyURL(dir)).contains("disk version"))
        #expect(!text(historyURL(dir)).contains("expired"))
    }

    @Test("A file that turns damaged while unreadable is backed up and its good records merged",
          .enabled(if: notRoot, "root ignores file modes"))
    func unreadableThenDamagedMerges() throws {
        let dir = makeDirectory()
        let a = record("good", age: day)
        try write("[\(try json(a))]", to: historyURL(dir))
        try setMode(0o000, historyURL(dir))
        defer { try? setMode(0o600, historyURL(dir)) }

        let loaded = history(dir)
        try setMode(0o600, historyURL(dir))
        let damaged = try write("[\(try json(a)),\(try undecodable("unknown"))]", to: historyURL(dir))
        loaded.add(record("new"))

        #expect(history(dir).records.map(\.text) == ["new", "good"])
        #expect(try backups(in: dir).map { try Data(contentsOf: $0) } == [damaged])
    }

    // MARK: - 4. Failed deletes and writes are reported, and retried

    @Test("Clear reports a failed delete, and a second Clear finishes it",
          .enabled(if: notRoot, "root ignores directory modes"))
    func clearFailureIsReported() throws {
        let dir = makeDirectory()
        try write("garbage", to: historyURL(dir))
        let loaded = history(dir)
        try setMode(0o500, dir)
        defer { try? setMode(0o700, dir) }

        #expect(!loaded.clear())
        #expect(loaded.deletionFailed)
        #expect(FileManager.default.fileExists(atPath: historyURL(dir).path))
        #expect(backups(in: dir).count == 1)

        try setMode(0o700, dir)
        #expect(loaded.clear())
        #expect(!loaded.deletionFailed)
        #expect(!FileManager.default.fileExists(atPath: historyURL(dir).path))
        #expect(backups(in: dir).isEmpty)
    }

    @Test("A failed off switch is reported and stays retryable",
          .enabled(if: notRoot, "root ignores directory modes"))
    func disableFailureIsRetryable() throws {
        let dir = makeDirectory()
        let loaded = history(dir)
        loaded.add(record("secret"))
        try setMode(0o500, dir)
        defer { try? setMode(0o700, dir) }

        #expect(!loaded.setEnabled(false))
        #expect(!loaded.isEnabled, "recording stops even if the delete failed")
        #expect(loaded.deletionFailed)
        #expect(text(historyURL(dir)).contains("secret"))

        try setMode(0o700, dir)
        #expect(loaded.setEnabled(false), "the same call again retries, not a no-op")
        #expect(!loaded.deletionFailed)
        #expect(!FileManager.default.fileExists(atPath: historyURL(dir).path))
    }

    @Test("A failed write is reported, keeps the old file, and the next save catches up",
          .enabled(if: notRoot, "root ignores directory modes"))
    func writeFailureIsReported() throws {
        let dir = makeDirectory()
        let loaded = history(dir)
        loaded.add(record("first"))
        let before = try Data(contentsOf: historyURL(dir))
        try setMode(0o500, dir)
        defer { try? setMode(0o700, dir) }

        loaded.add(record("second"))

        #expect(loaded.saveFailed)
        #expect(try Data(contentsOf: historyURL(dir)) == before)
        #expect(loaded.records.map(\.text) == ["second", "first"])

        try setMode(0o700, dir)
        loaded.add(record("third"))
        #expect(!loaded.saveFailed)
        #expect(history(dir).records.map(\.text) == ["third", "second", "first"])
    }

    @Test("An expired backup that cannot be deleted is reported until it is",
          .enabled(if: notRoot, "root ignores directory modes"))
    func retentionFailureIsReported() throws {
        let dir = makeDirectory()
        let loaded = history(dir, maxAge: nil)
        let old = dir.appendingPathComponent(backupName(daysBeforeNow: 400))
        try write("old copy", to: old)
        try setMode(0o500, dir)
        defer { try? setMode(0o700, dir) }

        loaded.maxAge = 30 * day
        #expect(loaded.deletionFailed)
        #expect(FileManager.default.fileExists(atPath: old.path))

        try setMode(0o700, dir)
        loaded.maxAge = 31 * day
        #expect(!loaded.deletionFailed)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}
