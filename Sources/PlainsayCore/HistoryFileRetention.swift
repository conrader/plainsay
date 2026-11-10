#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The age window, applied to damage backups.
///
/// A backup made before the cutoff goes whole: everything in it was written
/// before it was made. In a newer one, each record the scanner finds whose
/// date reads and is past the cutoff is cut out of the bytes, and *everything
/// else stays byte for byte* — records that are recent, records with no
/// readable date, a truncated tail, junk between elements. Content whose age
/// cannot be read is never deleted early on the strength of its neighbours;
/// it goes with the backup, one window after the backup was made.
///
/// Trimming never costs what it keeps: the trimmed copy replaces the backup
/// only once it is completely written, and if that fails the backup is left
/// exactly as it was and the failure is reported. A backup is deleted only
/// when what would remain holds nothing but array punctuation.
///
/// Privacy is checked, not remembered: every pass, window or not, every
/// backup it keeps is made private again and verified. A protection failure
/// is therefore reported on each pass until it is actually repaired; a retry
/// that has nothing left to trim cannot clear it by skipping the check.
extension HistoryFile {
    struct RetentionOutcome: Equatable {
        /// Some backup was deleted or rewritten.
        var changed = false
        /// Something past the cutoff, an abandoned stage, or a backup that is
        /// not verified private is still on disk.
        var failed = false
    }

    /// Sweeps abandoned stages of `url`, applies the age window (given a
    /// cutoff) to every backup of it, and verifies that every backup it keeps
    /// is private. `replace` and `protect` are seams for tests: to make the
    /// trimmed write fail while deleting would still succeed, and to make
    /// protection fail where the platform cannot (exclusion always succeeds
    /// off macOS).
    static func applyRetention(
        toBackupsOf url: URL, cutoff: Date?,
        replace: (URL, Data) -> Bool = { HistoryFile.replace($0, with: $1) },
        protect: (URL) -> Bool = { HistoryFile.makePrivate($0) }
    ) -> RetentionOutcome {
        var outcome = RetentionOutcome()
        if !removeAbandonedStages(of: url) { outcome.failed = true }
        guard let backups = backupEntries(of: url) else {
            outcome.failed = true
            return outcome
        }
        for backup in backups {
            // Not ours to rewrite or re-protect (chmod would follow a link):
            // Clear removes it, and the window by its name.
            let isRegular = linkStatus(backup.path).map {
                Int($0.st_mode) & Int(S_IFMT) == Int(S_IFREG)
            } ?? false
            guard let cutoff else {
                if isRegular, !protect(backup) { outcome.failed = true }
                continue
            }
            if backupDate(backup).map({ $0 < cutoff }) ?? true {
                outcome.changed = true
                if !remove(backup) { outcome.failed = true }
                continue
            }
            guard isRegular else { continue }
            guard let data = try? Data(contentsOf: backup) else {
                outcome.failed = true   // cannot tell what in it has expired
                if !protect(backup) { outcome.failed = true }
                continue
            }
            guard let trimmed = trimmed(data, cutoff: cutoff) else {
                // Nothing to trim, but kept: still has to be private. This is
                // also what a retry after a failed protection lands on.
                if !protect(backup) { outcome.failed = true }
                continue
            }
            outcome.changed = true
            if isPunctuationOnly(trimmed) {
                if !remove(backup) { outcome.failed = true }
            } else if !replace(backup, trimmed) {
                // Untouched, expired bytes still in it: reported, nothing
                // unexpired lost. Whatever it holds must still be private.
                outcome.failed = true
                _ = protect(backup)
            } else if !protect(backup) {
                // Replaced but not provably private: reported now, and
                // checked again by every later pass until it is.
                outcome.failed = true
            }
        }
        return outcome
    }

    /// `data` with every top-level record past `cutoff` cut out, or nil if
    /// none is. Each cut takes the record and the separator after it; all
    /// other bytes are kept, in order.
    static func trimmed(_ data: Data, cutoff: Date) -> Data? {
        let bytes = [UInt8](data)
        let expired = topLevelObjectRanges(in: bytes).filter { range in
            recordDate(Data(bytes[range])).map { $0 < cutoff } ?? false
        }
        guard !expired.isEmpty else { return nil }
        var kept: [UInt8] = []
        var cursor = 0
        for range in expired {
            kept.append(contentsOf: bytes[cursor..<range.lowerBound])
            cursor = range.upperBound
            var next = cursor
            while next < bytes.count, isWhitespace(bytes[next]) { next += 1 }
            if next < bytes.count, bytes[next] == UInt8(ascii: ",") { cursor = next + 1 }
        }
        kept.append(contentsOf: bytes[cursor...])
        return Data(kept)
    }

    /// Nothing left but a byte-order mark, whitespace, brackets and commas.
    static func isPunctuationOnly(_ data: Data) -> Bool {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        return bytes.allSatisfy {
            isWhitespace($0) || $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "]") || $0 == UInt8(ascii: ",")
        }
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
}
