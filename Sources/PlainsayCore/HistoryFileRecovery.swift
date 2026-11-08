import Foundation

/// Reading `history.json` without ever turning a bad read into an empty history.
///
/// The original loader did `(try? decoder.decode(...)) ?? []`: one record that
/// no longer decoded — a truncated write, an outcome added by a newer build, a
/// stray byte — made the whole file read as empty, and the next dictation's
/// `save()` then replaced every stored transcript with that one record. The
/// history exists so a lost paste is recoverable; it must not be the thing that
/// loses them.
///
/// So a load here distinguishes "nothing there" from "something there we could
/// not fully read", recovers each record that decodes on its own, and leaves a
/// byte-for-byte copy of anything it could not read beside the original.
enum HistoryFile {
    enum LoadResult: Equatable {
        /// No file. A fresh install, or history was cleared.
        case missing
        /// Every record decoded.
        case clean([TranscriptRecord])
        /// The file was read but not everything in it decoded. `records` holds
        /// whatever did, in file order; the bytes are kept for the backup.
        case damaged(records: [TranscriptRecord], original: Data)
        /// The file exists but could not be read at all (permissions, a
        /// directory in its place, an I/O error). Nothing is known about it,
        /// so nothing may replace it.
        case unreadable
    }

    /// Suffix for damage backups: `history.json.damaged-<UTC timestamp>`.
    static let backupMarker = ".damaged-"

    static func load(from url: URL) -> LoadResult {
        let path = url.path
        // `fileExists` is false for a dangling symlink; `attributesOfItem`
        // follows links too, so check the link itself as well.
        let exists = FileManager.default.fileExists(atPath: path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        guard exists else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }

        let decoder = makeDecoder()
        if let records = try? decoder.decode([TranscriptRecord].self, from: data) {
            return .clean(records)
        }
        let recovered = topLevelObjects(in: data).compactMap {
            try? decoder.decode(TranscriptRecord.self, from: $0)
        }
        return .damaged(records: recovered, original: data)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Splits a (possibly broken) top-level JSON array into the raw bytes of
    /// each object directly inside it, so every record can be decoded on its
    /// own. Tolerates a truncated tail and junk between elements; an element
    /// that never closes is dropped. Returns nothing if the data does not start
    /// with an array.
    ///
    /// This is a scanner, not a parser: it only tracks nesting and strings,
    /// which is all it takes to find where each record begins and ends.
    static func topLevelObjects(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var index = 0
        // Skip a UTF-8 byte-order mark and leading whitespace.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return [] }
        index += 1

        var objects: [Data] = []
        var depth = 1          // inside the top-level array
        var inString = false
        var escaped = false
        var objectStart: Int?

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    if depth == 1, byte == UInt8(ascii: "{") { objectStart = index }
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 1, byte == UInt8(ascii: "}"), let start = objectStart {
                        objects.append(Data(bytes[start...index]))
                        objectStart = nil
                    }
                    if depth == 0 { return objects }
                default:
                    break
                }
            }
            index += 1
        }
        return objects
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Copies `original` beside `url` as `<name>.damaged-<timestamp>[-n]`, and
    /// returns where it went — or nil if no verified copy could be made.
    ///
    /// Never overwrites anything: `copyItem` refuses an existing destination,
    /// and a clash moves on to the next suffix. The copy is read back and
    /// compared, so a short or failed write is not mistaken for a backup. If a
    /// backup with identical bytes already exists — the same damaged file seen
    /// on an earlier launch — that one is reused rather than piling up copies.
    static func backUp(_ url: URL, original: Data, now: Date) -> URL? {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + backupMarker

        if let existing = existingBackup(in: directory, prefix: prefix, matching: original) {
            return existing
        }

        let stamp = timestamp(now)
        for attempt in 0..<100 {
            let name = prefix + stamp + (attempt == 0 ? "" : "-\(attempt)")
            let destination = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                // A clash raced in between the check and the copy: try the
                // next name. Anything else will not get better by retrying.
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                return nil
            }
            PrivateFiles.protectWrittenFile(destination)
            // The file may have changed between our read and the copy; only a
            // copy of exactly what we failed to decode counts.
            guard (try? Data(contentsOf: destination)) == original else { return nil }
            return destination
        }
        return nil
    }

    private static func existingBackup(in directory: URL, prefix: String, matching original: Data) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        for name in names.sorted() where name.hasPrefix(prefix) {
            let candidate = directory.appendingPathComponent(name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: candidate.path))?[.size] as? NSNumber,
               size.intValue != original.count {
                continue
            }
            if (try? Data(contentsOf: candidate)) == original { return candidate }
        }
        return nil
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
