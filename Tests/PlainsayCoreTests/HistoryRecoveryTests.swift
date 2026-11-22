#if canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import PlainsayCore

/// A `history.json` that does not fully decode must never become an empty
/// history that the next save writes over the file.
///
/// Before this, `load()` was `(try? decode) ?? []`: one undecodable record
/// emptied the whole history, and the next dictation's `save()` replaced every
/// stored transcript with that single new one. Every test here runs against a
/// fresh temporary directory and asserts on the bytes on disk.
@Suite("History recovery")
@MainActor
struct HistoryRecoveryTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    private func makeDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plainsay-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func historyURL(_ dir: URL) -> URL { dir.appendingPathComponent("history.json") }

    private func record(_ text: String, age: TimeInterval = 0) -> TranscriptRecord {
        TranscriptRecord(
            date: fixedNow.addingTimeInterval(-age),
            text: text, rawText: text, outcome: .inserted,
            durationSeconds: 1, targetApp: "com.example.app"
        )
    }

    /// One record as the app writes it.
    private func json(_ record: TranscriptRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    /// A record this build cannot decode: an outcome from some other version.
    private func undecodable(_ text: String) throws -> String {
        try json(record(text)).replacingOccurrences(of: "\"inserted\"", with: "\"fromTheFuture\"")
    }

    private func write(_ text: String, to dir: URL) throws -> Data {
        let data = Data(text.utf8)
        try data.write(to: historyURL(dir))
        return data
    }

    private func backups(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("history.json" + HistoryFile.backupMarker) }
            .sorted().map { dir.appendingPathComponent($0) }
    }

    private func onDisk(_ dir: URL) -> Data? { try? Data(contentsOf: historyURL(dir)) }

    private func history(
        _ dir: URL, maxAge: TimeInterval? = nil, backUp: ((URL, Data, Date) -> URL?)? = nil
    ) -> TranscriptHistory {
        TranscriptHistory(
            limit: 100, maxAge: maxAge, isEnabled: true, directory: dir,
            now: { [fixedNow] in fixedNow },
            backUp: backUp ?? { HistoryFile.backUp($0, original: $1, now: $2) }
        )
    }

    // MARK: - The reported failure

    @Test("A corrupt file is backed up byte for byte, and left in place")
    func corruptFileIsBackedUp() throws {
        let dir = makeDirectory()
        let original = try write("{ this is not json at all", to: dir)

        let loaded = history(dir)

        #expect(loaded.records.isEmpty)
        #expect(loaded.diskState == .backedUp)
        let copies = backups(in: dir)
        #expect(copies.map(\.lastPathComponent) == ["history.json.damaged-20270115T080000Z"])
        #expect(try Data(contentsOf: copies[0]) == original)
        #expect(onDisk(dir) == original, "loading alone must not rewrite the file")
    }

    @Test("One bad record among good ones costs only that record")
    func oneBadRecordAmongGood() throws {
        let dir = makeDirectory()
        let first = record("first"), third = record("third")
        let original = try write(
            "[\(try json(first)),\(try undecodable("second")),\(try json(third))]", to: dir
        )

        let loaded = history(dir)

        #expect(loaded.records.map(\.id) == [first.id, third.id])
        #expect(loaded.records.map(\.text) == ["first", "third"])
        #expect(try backups(in: dir).map { try Data(contentsOf: $0) } == [original])
    }

    @Test("Saving after a failed load keeps everything: new file plus the untouched backup")
    func saveAfterFailedLoad() throws {
        let dir = makeDirectory()
        let survivor = record("survivor")
        let original = try write("[\(try json(survivor)),\(try undecodable("lost"))]", to: dir)

        let loaded = history(dir)
        loaded.add(record("new dictation"))

        // The live file holds what was recovered plus the new record...
        let reopened = history(dir)
        #expect(reopened.records.map(\.text) == ["new dictation", "survivor"])
        #expect(reopened.diskState == .owned)
        // ...and the original, including the record we could not read, is intact.
        #expect(try backups(in: dir).map { try Data(contentsOf: $0) } == [original])
    }

    @Test("The old wipe: a fully undecodable file plus one dictation no longer loses the file")
    func undecodableThenAddKeepsOriginal() throws {
        let dir = makeDirectory()
        let original = try write("[\(try undecodable("a")),\(try undecodable("b"))]", to: dir)

        history(dir).add(record("only new"))

        #expect(try backups(in: dir).map { try Data(contentsOf: $0) } == [original])
        #expect(history(dir).records.map(\.text) == ["only new"])
    }

    // MARK: - Empty never overwrites

    @Test("An empty history does not overwrite a damaged file that could not be backed up")
    func emptyDoesNotOverwriteDamaged() throws {
        let dir = makeDirectory()
        let original = try write(
            "[\(try json(record("old", age: 400 * day))),\(try undecodable("bad"))]", to: dir
        )
        let loaded = history(dir, maxAge: nil, backUp: { _, _, _ in nil })
        #expect(loaded.records.count == 1)
        #expect(loaded.diskState == .protected)

        // Pruning empties the in-memory history and asks for a save.
        loaded.maxAge = 30 * day

        #expect(loaded.records.isEmpty)
        #expect(onDisk(dir) == original)
    }

    @Test("Pruning a clean file to empty still writes, as before")
    func pruneCleanFileToEmptyStillWrites() throws {
        let dir = makeDirectory()
        _ = try write("[\(try json(record("ancient", age: 400 * day)))]", to: dir)

        let loaded = history(dir, maxAge: 30 * day)

        #expect(loaded.records.isEmpty)
        #expect(!String(decoding: onDisk(dir) ?? Data(), as: UTF8.self).contains("ancient"))
        #expect(backups(in: dir).isEmpty)
    }

    // MARK: - Backup and read failures

    @Test("If the backup fails, the damaged file is never replaced")
    func backupFailureBlocksWrites() throws {
        let dir = makeDirectory()
        let original = try write("[\(try json(record("keep"))),\(try undecodable("x"))]", to: dir)

        let loaded = history(dir, backUp: { _, _, _ in nil })
        #expect(loaded.diskState == .protected)
        loaded.add(record("in memory only"))

        #expect(loaded.saveFailed)
        #expect(loaded.records.map(\.text) == ["in memory only", "keep"])
        #expect(onDisk(dir) == original)
        #expect(backups(in: dir).isEmpty)
    }

    @Test("A backup that starts working later unblocks saving, copying first")
    func backupRetriedOnNextSave() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recentBad = try undecodable("recent damage")
        let undated = #"{"text":"undated damage"}"#
        let original = try write(
            "[\(try json(record("expired", age: 400 * day))),\(recentBad),\(undated)]", to: dir
        )
        final class Switch { var on = false }
        let backupWorks = Switch()

        let loaded = history(dir, maxAge: 30 * day, backUp: { url, data, now in
            backupWorks.on ? HistoryFile.backUp(url, original: data, now: now) : nil
        })
        loaded.add(record("first try"))
        #expect(onDisk(dir) == original)
        #expect(loaded.saveFailed)

        backupWorks.on = true
        loaded.add(record("second try"))
        #expect(!loaded.saveFailed)

        // Inspect before reopening: launch would run retention and hide the bug.
        #expect(try backups(in: dir).map { try Data(contentsOf: $0) }
            == [Data("[\(recentBad),\(undated)]".utf8)])
        #expect(!loaded.deletionFailed)
        #expect(history(dir).records.map(\.text) == ["second try", "first try"])
    }

    @Test("Retry applies retention to its new backup and preserves protection failures", arguments: [true, false])
    func retrySweepsNewBackup(protectionWorksInitially: Bool) throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recentBad = try undecodable("recent damage")
        let undated = #"{"text":"undated damage"}"#
        let original = try write(
            "[\(try json(record("expired", age: 400 * day))),\(recentBad),\(undated)]", to: dir
        )
        var backupWorks = false
        var protectionWorks = protectionWorksInitially
        let loaded = TranscriptHistory(
            limit: 100, maxAge: 30 * day, isEnabled: true, directory: dir,
            now: { [fixedNow] in fixedNow },
            backUp: { url, data, now in
                backupWorks ? HistoryFile.backUp(url, original: data, now: now) : nil
            },
            protectBackup: { protectionWorks && HistoryFile.makePrivate($0) }
        )
        #expect(loaded.deletionFailed && loaded.unsavedInMemory)
        #expect(onDisk(dir) == original)
        #expect(backups(in: dir).isEmpty)

        backupWorks = true
        #expect(loaded.retryDeletion() == protectionWorksInitially)
        #expect(loaded.deletionFailed == !protectionWorksInitially)
        #expect(!loaded.saveFailed && !loaded.unsavedInMemory)
        // The backup loses only dated expired bytes, before any later pass.
        #expect(try backups(in: dir).map { try Data(contentsOf: $0) }
            == [Data("[\(recentBad),\(undated)]".utf8)])
        #expect(!String(decoding: onDisk(dir) ?? Data(), as: UTF8.self).contains("expired"))

        protectionWorks = true
        #expect(loaded.retryDeletion())
        #expect(!loaded.deletionFailed)
    }

    @Test("A file that exists but cannot be read is never replaced",
          .enabled(if: getuid() != 0, "root ignores file modes"))
    func unreadableFileIsProtected() throws {
        let dir = makeDirectory()
        let original = try write("[\(try json(record("secret")))]", to: dir)
        let url = historyURL(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        try #require(!FileManager.default.isReadableFile(atPath: url.path))

        let loaded = history(dir)
        #expect(loaded.diskState == .protected)
        loaded.add(record("new"))
        #expect(loaded.saveFailed)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(onDisk(dir) == original)
    }

    // MARK: - Boundaries

    @Test("A truncated file keeps every record that was written in full")
    func truncatedFile() throws {
        let dir = makeDirectory()
        let a = record("a"), b = record("b")
        let full = "[\(try json(a)),\(try json(b)),\(try json(record("c")))]"
        _ = try write(String(full.dropLast(20)), to: dir)

        #expect(history(dir).records.map(\.id) == [a.id, b.id])
        #expect(backups(in: dir).count == 1)
    }

    @Test("An empty file is treated as damaged, not as an empty history")
    func zeroByteFile() throws {
        let dir = makeDirectory()
        _ = try write("", to: dir)

        let loaded = history(dir)

        #expect(loaded.records.isEmpty)
        #expect(loaded.diskState == .backedUp)
        #expect(backups(in: dir).count == 1)
    }

    @Test("A clean file makes no backup")
    func cleanFileNoBackup() throws {
        let dir = makeDirectory()
        _ = try write("[\(try json(record("fine")))]", to: dir)

        let loaded = history(dir)

        #expect(loaded.records.map(\.text) == ["fine"])
        #expect(loaded.diskState == .owned)
        #expect(backups(in: dir).isEmpty)
    }

    @Test("Relaunching on the same damaged file reuses its backup")
    func relaunchDoesNotPileUpBackups() throws {
        let dir = makeDirectory()
        _ = try write("garbage", to: dir)

        _ = history(dir)
        _ = TranscriptHistory(directory: dir) // real clock, later timestamp

        #expect(backups(in: dir).count == 1)
    }

    @Test("A backup name already taken is never overwritten")
    func backupNameClash() throws {
        let dir = makeDirectory()
        let original = try write("garbage", to: dir)
        let taken = dir.appendingPathComponent("history.json.damaged-20270115T080000Z")
        try Data("someone else's".utf8).write(to: taken)

        _ = history(dir)

        #expect(try Data(contentsOf: taken) == Data("someone else's".utf8))
        let fresh = dir.appendingPathComponent("history.json.damaged-20270115T080000Z-1")
        #expect(try Data(contentsOf: fresh) == original)
    }

    @Test("Clearing after a damaged load deletes the live file and its backups")
    func clearDeletesBackups() throws {
        let dir = makeDirectory()
        _ = try write("garbage", to: dir)
        let loaded = history(dir)
        #expect(backups(in: dir).count == 1)

        #expect(loaded.clear())

        #expect(onDisk(dir) == nil)
        #expect(backups(in: dir).isEmpty, "Clear says it deleted what was saved; a copy must not survive")
        #expect(!loaded.deletionFailed)
        loaded.add(record("after clear"))
        #expect(history(dir).records.map(\.text) == ["after clear"])
    }

    @Test("Backups are private like the history itself")
    func backupIsPrivate() throws {
        let dir = makeDirectory()
        _ = try write("garbage", to: dir)
        _ = history(dir)

        let copy = try #require(backups(in: dir).first)
        let mode = (try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }
}

@Suite("History file scanner")
struct HistoryFileScannerTests {
    private func objects(_ text: String) -> [String] {
        HistoryFile.topLevelObjects(in: Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("Braces and escaped quotes inside strings do not split a record")
    func stringsAreOpaque() {
        let text = #"[{"text":"a } \" { ] b","n":[1,{"x":2}]},{"y":3}]"#
        #expect(objects(text) == [#"{"text":"a } \" { ] b","n":[1,{"x":2}]}"#, #"{"y":3}"#])
    }

    @Test("Anything but a top-level array yields nothing")
    func notAnArray() {
        #expect(objects(#"{"a":1}"#).isEmpty)
        #expect(objects("").isEmpty)
        #expect(objects("   ").isEmpty)
    }

    @Test("A byte-order mark and whitespace before the array are tolerated")
    func bomAndWhitespace() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("\n [ {\"a\":1} ]".utf8)
        #expect(HistoryFile.topLevelObjects(in: data).count == 1)
    }

    @Test("An unterminated last record is dropped, earlier ones kept")
    func unterminatedTail() {
        #expect(objects(#"[{"a":1},{"b":"#) == [#"{"a":1}"#])
    }
}
