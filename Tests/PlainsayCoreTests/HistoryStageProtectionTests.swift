#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import PlainsayCore

/// Two promises that every retention pass keeps, window or not:
///
/// - No stage escapes the sweep, whatever file it was replacing: a backup's
///   stage is named in the live file's namespace, and one left with the older
///   backup-derived name (`history.json.damaged-<stamp>.staging-<uuid>`) is
///   swept too, never aged or reused as a backup.
/// - A backup that could not be made private keeps the failure reported until
///   a later pass verifies it private; retrying cannot clear it by skipping
///   the check.
///
/// Every test uses a fresh temporary directory, removed afterwards.
@Suite("History stages and backup protection")
@MainActor
struct HistoryStageProtectionTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-stages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            _ = chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func liveURL(_ dir: URL) -> URL { dir.appendingPathComponent("history.json") }

    private func backupURL(_ dir: URL, made: Date) -> URL {
        dir.appendingPathComponent("history.json" + HistoryFile.backupMarker + HistoryFile.timestamp(made))
    }

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

    /// A record cut off mid-write: never closes, so no date can be read from it.
    private func partial(_ text: String, age: TimeInterval) throws -> String {
        let whole = try json(record(text, age: age))
        return String(whole.prefix(upTo: whole.range(of: text)!.upperBound))
    }

    private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

    private func text(_ url: URL) -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func history(_ dir: URL, maxAge: TimeInterval?, protect: @escaping (URL) -> Bool) -> TranscriptHistory {
        TranscriptHistory(
            limit: 100, maxAge: maxAge, isEnabled: true, directory: dir,
            now: { [fixedNow] in fixedNow },
            backUp: { HistoryFile.backUp($0, original: $1, now: $2) },
            protectBackup: protect
        )
    }

    /// The name the previous build gave a backup's stage.
    private func legacyStage(of backup: URL) -> URL {
        backup.deletingLastPathComponent()
            .appendingPathComponent(backup.lastPathComponent + HistoryFile.stagingMarker + UUID().uuidString)
    }

    // MARK: - 1. One stage namespace

    @Test("A backup's stage is generated in the live file's stage namespace")
    func backupStageNamespace() throws {
        try withDirectory { dir in
            let backup = backupURL(dir, made: fixedNow)
            let stage = HistoryFile.stagingURL(for: backup)
            #expect(stage.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
            #expect(stage.lastPathComponent.hasPrefix("history.json" + HistoryFile.stagingMarker))
            #expect(!stage.lastPathComponent.contains(HistoryFile.backupMarker))
            #expect(HistoryFile.stagingURL(for: liveURL(dir)).lastPathComponent
                .hasPrefix("history.json" + HistoryFile.stagingMarker))
        }
    }

    @Test("An abandoned backup stage with its real generated name is swept, with and without a window",
          arguments: [nil, 30.0])
    func generatedBackupStageIsSwept(windowDays: Double?) throws {
        try withDirectory { dir in
            let stage = HistoryFile.stagingURL(for: backupURL(dir, made: fixedNow))
            try write("[" + (try partial("half-trimmed secret", age: 1 * day)), to: stage)

            let loaded = history(dir, maxAge: windowDays.map { $0 * day }, protect: { HistoryFile.makePrivate($0) })

            #expect(names(dir).isEmpty, "only the abandoned stage was there, and it must be gone")
            #expect(loaded.records.isEmpty)
            #expect(!loaded.deletionFailed)
        }
    }

    @Test("A stage left with the older backup-derived name is swept, never aged as a backup",
          arguments: [nil, 30.0])
    func legacyBackupStageIsSwept(windowDays: Double?) throws {
        try withDirectory { dir in
            // Recent stamp: under the old sweep this survived as a "backup"
            // until the window, or for ever with no window.
            let stage = legacyStage(of: backupURL(dir, made: fixedNow))
            try write("[" + (try partial("half-trimmed secret", age: 1 * day)), to: stage)
            #expect(HistoryFile.backupEntries(of: liveURL(dir)) == [], "a stage is not a backup")

            let loaded = history(dir, maxAge: windowDays.map { $0 * day }, protect: { HistoryFile.makePrivate($0) })

            #expect(names(dir).isEmpty)
            #expect(!loaded.deletionFailed)

            try write("secret", to: stage)
            #expect(loaded.clear())
            #expect(names(dir).isEmpty)
        }
    }

    @Test("A stage holding the damaged file's exact bytes is never reused as its backup")
    func stageIsNotReusedAsBackup() throws {
        try withDirectory { dir in
            let original = "[\(try json(record("good"))),garbage"
            try write(original, to: liveURL(dir))
            let stage = legacyStage(of: backupURL(dir, made: fixedNow.addingTimeInterval(-day)))
            try write(original, to: stage)
            _ = chmod(stage.path, 0o600)

            let loaded = history(dir, maxAge: nil, protect: { HistoryFile.makePrivate($0) })

            #expect(loaded.diskState == .backedUp)
            let backups = try #require(HistoryFile.backupEntries(of: liveURL(dir)))
            #expect(backups.count == 1)
            #expect(backups.first.map(text) == original, "the swept stage must not have been the only copy")
            #expect(!FileManager.default.fileExists(atPath: stage.path))
        }
    }

    // MARK: - 2. A protection failure is kept until it is repaired

    @Test("A failed protection after a successful trim survives every retry until it is repaired")
    func protectionFailureSurvivesRetry() throws {
        try withDirectory { dir in
            let tail = try partial("recenttail", age: 1 * day)
            try write("[\(try json(record("ancient", age: 400 * day))),\n\(tail)", to: liveURL(dir))
            var protectionWorks = false
            var calls = 0
            let loaded = history(dir, maxAge: 30 * day, protect: { url in
                calls += 1
                return protectionWorks && HistoryFile.makePrivate(url)
            })
            let backup = try #require(HistoryFile.backupEntries(of: liveURL(dir))?.first)
            #expect(text(backup) == "[\n" + tail, "the trim itself succeeded")
            #expect(loaded.deletionFailed, "the trimmed backup is not verified private")

            for attempt in 1...3 {
                let before = calls
                #expect(!loaded.retryDeletion(), "retry \(attempt) has nothing to trim, but protection still fails")
                #expect(loaded.deletionFailed)
                #expect(calls > before, "retry \(attempt) must check protection again")
            }
            loaded.maxAge = nil   // no window: still checked
            #expect(loaded.deletionFailed)
            loaded.maxAge = 30 * day
            #expect(!loaded.applyPolicy(isEnabled: true, maxAge: 30 * day))

            protectionWorks = true
            #expect(loaded.retryDeletion())
            #expect(!loaded.deletionFailed)
            #expect(text(backup) == "[\n" + tail, "rechecking never changes what the backup holds")
        }
    }

    @Test("Each pass reports a protection failure, window or not, until one verifies it")
    func retentionRechecksProtection() throws {
        try withDirectory { dir in
            let backup = backupURL(dir, made: fixedNow)
            try write("[" + (try partial("recent", age: 1 * day)), to: backup)
            let cutoff = fixedNow.addingTimeInterval(-30 * day)

            for pass in [cutoff, nil, cutoff] as [Date?] {
                let failing = HistoryFile.applyRetention(toBackupsOf: liveURL(dir), cutoff: pass, protect: { _ in false })
                #expect(failing == .init(changed: false, failed: true))
            }
            let repaired = HistoryFile.applyRetention(toBackupsOf: liveURL(dir), cutoff: cutoff)
            #expect(repaired == .init(changed: false, failed: false))
        }
    }

    @Test("A kept backup that lost owner-only mode is repaired by the next pass, window or not",
          arguments: [nil, 30.0])
    func keptBackupModeIsRepaired(windowDays: Double?) throws {
        try withDirectory { dir in
            let backup = backupURL(dir, made: fixedNow)
            try write("[" + (try partial("recent", age: 1 * day)), to: backup)
            _ = chmod(backup.path, 0o644)

            let cutoff = windowDays.map { fixedNow.addingTimeInterval(-$0 * day) }
            let outcome = HistoryFile.applyRetention(toBackupsOf: liveURL(dir), cutoff: cutoff)

            #expect(outcome == .init(changed: false, failed: false))
            #expect(mode(backup) == 0o600)
        }
    }
}
