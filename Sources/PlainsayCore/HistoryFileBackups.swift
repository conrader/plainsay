#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Damage backups: `history.json.damaged-<UTC stamp>[-n]`, beside the history.
///
/// A backup is a copy of transcripts, so it is held to the same promises as
/// the history itself:
///
/// - It is private: an independent regular file (never a link to anything),
///   owner-only, and on macOS excluded from backups. A candidate that is not
///   is never trusted to hold the only copy of a damaged file.
/// - Clear and the off switch delete it, along with `history.json`.
/// - The age window applies to it (see `HistoryFileRetention.swift`).
///
/// Every file that replaces one of these is first written in full to a
/// staging file, `history.json.staging-<uuid>`, and renamed into place. A
/// stage is a copy of transcripts too, so it is named where Clear, the off
/// switch and every retention pass find it: one left by a crash is deleted,
/// never adopted.
extension HistoryFile {
    /// Suffix for damage backups: `history.json.damaged-<UTC timestamp>`.
    static let backupMarker = ".damaged-"

    /// Suffix for staging files: `history.json.staging-<uuid>`.
    static let stagingMarker = ".staging-"

    /// Owner-only, for files that hold transcripts.
    private static let privateMode: mode_t = 0o600

    // MARK: - Making a backup

    /// Writes `original` beside `url` as `<name>.damaged-<timestamp>[-n]`, and
    /// returns where it went — or nil if no verified, private copy exists.
    ///
    /// Never overwrites anything: the file is created exclusively (`O_EXCL`,
    /// `O_NOFOLLOW`) with owner-only permissions, and a clash moves on to the
    /// next suffix. The copy is written from the bytes that were read, so a
    /// link at `url` cannot make it an alias of the live file, and it is read
    /// back before it counts. If an independent, private backup with identical
    /// bytes already exists — the same damaged file seen on an earlier launch —
    /// that one is reused rather than piling up copies.
    static func backUp(_ url: URL, original: Data, now: Date) -> URL? {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + backupMarker

        if let existing = existingBackup(in: directory, prefix: prefix, of: url, matching: original) {
            return existing
        }

        let stamp = timestamp(now)
        for attempt in 0..<100 {
            let name = prefix + stamp + (attempt == 0 ? "" : "-\(attempt)")
            let destination = directory.appendingPathComponent(name)
            switch createExclusively(destination, with: original) {
            case .exists:
                continue
            case .failed:
                Log.history.error("history backup could not be written: \(name, privacy: .public)")
                return nil
            case .created:
                guard isTrustedBackup(destination, of: url, matching: original) else {
                    // Ours, and a copy of bytes still in the live file: removing
                    // it loses nothing, and leaves no unverified transcript copy.
                    try? FileManager.default.removeItem(at: destination)
                    Log.history.error("history backup failed verification: \(name, privacy: .public)")
                    return nil
                }
                return destination
            }
        }
        return nil
    }

    private static func existingBackup(
        in directory: URL, prefix: String, of live: URL, matching original: Data
    ) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        for name in names.sorted() where name.hasPrefix(prefix) {
            let candidate = directory.appendingPathComponent(name)
            if isTrustedBackup(candidate, of: live, matching: original) { return candidate }
        }
        return nil
    }

    /// Whether `candidate` can stand in for the live file: a regular file of
    /// our own, not a link or another name for the live file, holding exactly
    /// `original`, and private — protection is applied if missing, then checked.
    static func isTrustedBackup(_ candidate: URL, of live: URL, matching original: Data) -> Bool {
        guard let info = linkStatus(candidate.path),
              Int(info.st_mode) & Int(S_IFMT) == Int(S_IFREG),
              info.st_nlink == 1,             // no second name, live or otherwise
              info.st_uid == getuid(),
              Int(info.st_size) == original.count else { return false }
        if let target = status(live.path), target.st_dev == info.st_dev, target.st_ino == info.st_ino {
            return false
        }
        guard (try? Data(contentsOf: candidate)) == original else { return false }
        return makePrivate(candidate)
    }

    /// Applies owner-only permissions and backup exclusion, then reads both
    /// back. A copy we cannot make private is not a copy we may rely on.
    static func makePrivate(_ url: URL) -> Bool {
        if let info = linkStatus(url.path), Int(info.st_mode) & 0o077 != 0 {
            _ = chmod(url.path, privateMode)
        }
        guard let after = linkStatus(url.path), Int(after.st_mode) & 0o077 == 0 else { return false }
        PrivateFiles.excludeFromBackup(url)
        return PrivateFiles.isExcludedFromBackup(url)
    }

    // MARK: - Deleting

    /// Every directory entry named as a backup of `url`, of whatever type.
    /// Nil if the directory exists but cannot be listed.
    static func backupEntries(of url: URL) -> [URL]? {
        entries(of: url, marker: backupMarker)
    }

    /// Every staging file of `url`. Writes are synchronous and single-writer,
    /// so any that exists between two operations was abandoned by a crash.
    static func stagingEntries(of url: URL) -> [URL]? {
        entries(of: url, marker: stagingMarker)
    }

    private static func entries(of url: URL, marker: String) -> [URL]? {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + marker
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(prefix) }.sorted()
                .map { directory.appendingPathComponent($0) }
        } catch {
            return isAbsent(directory.path) ? [] : nil
        }
    }

    /// Removes the entry at `url` itself (a link, not what it points to).
    /// True only once nothing is left there.
    @discardableResult
    static func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Fall through: "already gone" is success, anything else is not.
        }
        return isAbsent(url.path)
    }

    /// Removes `url`, every backup of it and every abandoned stage. True only
    /// if all of them are gone.
    static func removeWithBackups(_ url: URL) -> Bool {
        let liveGone = remove(url)
        return removeCopies(of: url) && liveGone
    }

    /// Removes every backup and staging file of `url`, leaving `url` itself.
    static func removeCopies(of url: URL) -> Bool {
        // Both, whatever the first one did.
        let stagesGone = removeAbandonedStages(of: url)
        let backupsGone = removeAll(backupEntries(of: url))
        return stagesGone && backupsGone
    }

    /// Removes every staging file of `url`. True only if none is left.
    static func removeAbandonedStages(of url: URL) -> Bool {
        removeAll(stagingEntries(of: url))
    }

    private static func removeAll(_ entries: [URL]?) -> Bool {
        guard let entries else { return false }
        return entries.map { remove($0) }.allSatisfy { $0 }
    }

    // MARK: - Replacing

    /// Replaces `url` with `data`, all or nothing: the bytes are written in
    /// full to an owner-only staging file beside it, flushed, and renamed over
    /// `url`. On failure `url` is as it was and no stage is left behind (and
    /// one left by a crash is swept by the next Clear or retention pass).
    ///
    /// Takes the place of `Data.write(options: .atomic)`, whose temporary file
    /// is named and placed where nothing here could find it again.
    static func replace(_ url: URL, with data: Data) -> Bool {
        let directory = url.deletingLastPathComponent()
        let stage = directory.appendingPathComponent(
            url.lastPathComponent + stagingMarker + UUID().uuidString)
        guard createExclusively(stage, with: data) == .created else { return false }
        // Set on the stage so the replacement is never, even briefly, an
        // unexcluded transcript; checked again on the result by the caller.
        PrivateFiles.excludeFromBackup(stage)
        guard rename(stage.path, url.path) == 0 else {
            remove(stage)
            return false
        }
        syncDirectory(directory)
        return true
    }

    /// Makes a rename durable. Best effort: the data itself is already synced.
    private static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        _ = close(descriptor)
    }

    // MARK: - Low level

    private enum CreateResult { case created, exists, failed }

    /// Creates `url` owner-only, refusing an existing entry or a link, and
    /// writes all of `data` to it. A partial file is removed.
    private static func createExclusively(_ url: URL, with data: Data) -> CreateResult {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, privateMode)
        guard descriptor >= 0 else { return errno == EEXIST ? .exists : .failed }
        var written = 0
        let complete = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            while written < buffer.count {
                let count = write(descriptor, base + written, buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                // No progress and no error: give up rather than spin.
                if count == 0 { return false }
                written += count
            }
            return true
        }
        let synced = fsync(descriptor) == 0
        let closed = close(descriptor) == 0
        guard complete, synced, closed else {
            _ = unlink(url.path)
            return .failed
        }
        return .created
    }

    static func linkStatus(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    private static func status(_ path: String) -> stat? {
        var info = stat()
        return stat(path, &info) == 0 ? info : nil
    }

    /// Absent means `lstat` says no such entry — not merely that a lookup failed.
    static func isAbsent(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    static func timestamp(_ date: Date) -> String {
        timestampFormatter().string(from: date)
    }
}
