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
extension HistoryFile {
    struct RetentionOutcome: Equatable {
        /// Some backup was deleted or rewritten.
        var changed = false
        /// Something past the cutoff, an abandoned stage, or a backup that
        /// could not be kept private is still on disk.
        var failed = false
    }

    /// Sweeps abandoned stages of `url` and, given a cutoff, applies the age
    /// window to every backup of it. `replace` is a seam for tests, to make
    /// the trimmed write fail while deleting would still succeed.
    static func applyRetention(
        toBackupsOf url: URL, cutoff: Date?,
        replace: (URL, Data) -> Bool = { HistoryFile.replace($0, with: $1) }
    ) -> RetentionOutcome {
        var outcome = RetentionOutcome()
        if !removeAbandonedStages(of: url) { outcome.failed = true }
        guard let cutoff else { return outcome }
        guard let backups = backupEntries(of: url) else {
            outcome.failed = true
            return outcome
        }
        for backup in backups {
            if backupDate(backup).map({ $0 < cutoff }) ?? true {
                outcome.changed = true
                if !remove(backup) { outcome.failed = true }
                continue
            }
            // Not ours to rewrite: Clear removes it, and its age by name.
            guard let info = linkStatus(backup.path),
                  Int(info.st_mode) & Int(S_IFMT) == Int(S_IFREG) else { continue }
            guard let data = try? Data(contentsOf: backup) else {
                outcome.failed = true   // cannot tell what in it has expired
                continue
            }
            guard let trimmed = trimmed(data, cutoff: cutoff) else { continue }
            outcome.changed = true
            if isPunctuationOnly(trimmed) {
                if !remove(backup) { outcome.failed = true }
            } else if !replace(backup, trimmed) || !makePrivate(backup) {
                // Either the backup is untouched (expired bytes still in it),
                // or it was replaced but is not provably private. Both are
                // reported, and nothing unexpired has been lost.
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
