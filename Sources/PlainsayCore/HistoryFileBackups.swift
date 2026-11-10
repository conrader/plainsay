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
/// - The age window applies to it. A backup made before the cutoff goes whole
///   (everything in it was written before it was made). In a newer one, every
///   record whose date can still be read and is past the cutoff is cut out,
///   and the rest is kept byte for byte.
///
/// Content with no readable date cannot be aged by its own date; it is gone at
/// the latest one window after the backup was made.
extension HistoryFile {
    /// Suffix for damage backups: `history.json.damaged-<UTC timestamp>`.
    static let backupMarker = ".damaged-"

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
    private static func makePrivate(_ url: URL) -> Bool {
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
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + backupMarker
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

    /// Removes `url` and every backup of it. True only if all of them are gone.
    static func removeWithBackups(_ url: URL) -> Bool {
        let liveGone = remove(url)
        guard let backups = backupEntries(of: url) else { return false }
        let backupsGone = backups.map { remove($0) }.allSatisfy { $0 }
        return liveGone && backupsGone
    }

    // MARK: - Retention

    struct RetentionOutcome: Equatable {
        /// Some backup was deleted or rewritten.
        var changed = false
        /// Something past the cutoff is still on disk.
        var failed = false
    }

    /// Applies the age window to every backup of `url`.
    static func applyRetention(toBackupsOf url: URL, cutoff: Date) -> RetentionOutcome {
        var outcome = RetentionOutcome()
        guard let backups = backupEntries(of: url) else {
            outcome.failed = true
            return outcome
        }
        for backup in backups {
            let made = backupDate(backup)
            if made.map({ $0 < cutoff }) ?? true {
                outcome.changed = true
                if !remove(backup) { outcome.failed = true }
                continue
            }
            guard let info = linkStatus(backup.path),
                  Int(info.st_mode) & Int(S_IFMT) == Int(S_IFREG),
                  let data = try? Data(contentsOf: backup) else { continue }
            let objects = topLevelObjects(in: data)
            let kept = objects.filter { object in recordDate(object).map { $0 >= cutoff } ?? true }
            guard kept.count != objects.count else { continue }
            outcome.changed = true
            if kept.isEmpty || !rewrite(backup, keeping: kept) {
                if !remove(backup) { outcome.failed = true }
            }
        }
        return outcome
    }

    /// When the backup was made: its name's stamp, else its own mtime.
    private static func backupDate(_ url: URL) -> Date? {
        let name = url.lastPathComponent
        if let range = name.range(of: backupMarker) {
            let stamp = String(name[range.upperBound...].prefix(16))
            if let date = timestampFormatter().date(from: stamp) { return date }
        }
        guard let info = linkStatus(url.path) else { return nil }
        #if canImport(Darwin)
        let seconds = info.st_mtimespec.tv_sec
        #else
        let seconds = info.st_mtim.tv_sec
        #endif
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// A record's `date`, read without requiring the record to decode.
    private static func recordDate(_ object: Data) -> Date? {
        guard let fields = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any],
              let value = fields["date"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Replaces `backup` with an array of just `objects`, raw bytes unchanged.
    private static func rewrite(_ backup: URL, keeping objects: [Data]) -> Bool {
        var data = Data("[".utf8)
        for (index, object) in objects.enumerated() {
            if index > 0 { data.append(Data(",\n".utf8)) }
            data.append(object)
        }
        data.append(Data("]".utf8))
        // Not named like a backup, so a crash cannot leave it treated as one.
        let temporary = backup.deletingLastPathComponent()
            .appendingPathComponent(".rewrite-\(UUID().uuidString)")
        guard createExclusively(temporary, with: data) == .created else { return false }
        guard rename(temporary.path, backup.path) == 0 else {
            remove(temporary)
            return false
        }
        PrivateFiles.excludeFromBackup(backup)
        return true
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

    private static func linkStatus(_ path: String) -> stat? {
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

    private static func timestampFormatter() -> DateFormatter {
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
