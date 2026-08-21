import AppKit
import Foundation
import Observation

public struct TranscriptRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    /// What was actually inserted (cleaned, or raw if cleanup failed).
    public let text: String
    /// The unpolished transcript, kept so a bad cleanup is recoverable.
    public let rawText: String
    public let outcome: DictationOutcome
    public let durationSeconds: Double
    /// Bundle id of the app it was aimed at.
    public let targetApp: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        rawText: String,
        outcome: DictationOutcome,
        durationSeconds: Double,
        targetApp: String?
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.rawText = rawText
        self.outcome = outcome
        self.durationSeconds = durationSeconds
        self.targetApp = targetApp
    }
}

/// Keeps the last N dictations on disk.
///
/// This exists because pasting into another app is the one step Plainsay cannot
/// verify. If a paste silently fails — the target app was busy, Accessibility
/// was revoked, focus moved — the words are gone and no amount of logging
/// brings them back. Writing every transcript down first means the worst case
/// is "copy it from the menu", not "say it all again".
@MainActor
@Observable
public final class TranscriptHistory {
    public private(set) var records: [TranscriptRecord] = []

    private let limit: Int
    private let fileURL: URL

    public init(limit: Int = 100, directory: URL? = nil) {
        self.limit = limit

        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plainsay", isDirectory: true)

        PrivateFiles.makePrivateDirectory(at: base)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    public var mostRecent: TranscriptRecord? { records.first }
    public var hasUnacknowledgedInsertion: Bool {
        records.contains { $0.outcome == .insertionUnverified }
    }

    public func add(_ record: TranscriptRecord) {
        records.insert(record, at: 0)
        if records.count > limit {
            records.removeLast(records.count - limit)
        }
        save()
    }

    /// Persists that the user has dealt with every outstanding paste warning.
    /// The history rows still say those dictations were not pasted; only the
    /// menu reminder is acknowledged.
    public func acknowledgeInsertionIssues() {
        var changed = false
        records = records.map { record in
            guard record.outcome == .insertionUnverified else { return record }
            changed = true
            return replacingOutcome(of: record, with: .insertionUnverifiedAcknowledged)
        }
        if changed { save() }
    }

    /// The transcript is saved before insertion is attempted. If that later
    /// step falls back to the clipboard, amend the existing record rather than
    /// adding a duplicate or leaving history claiming it was inserted.
    public func updateOutcome(id: UUID, to outcome: DictationOutcome) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[index]
        guard record.outcome != outcome else { return }
        records[index] = replacingOutcome(of: record, with: outcome)
        save()
    }

    private func replacingOutcome(of record: TranscriptRecord, with outcome: DictationOutcome) -> TranscriptRecord {
        TranscriptRecord(
            id: record.id,
            date: record.date,
            text: record.text,
            rawText: record.rawText,
            outcome: outcome,
            durationSeconds: record.durationSeconds,
            targetApp: record.targetApp
        )
    }

    public func clear() {
        records = []
        save()
    }

    /// Puts a past dictation back on the clipboard so it can be pasted by hand.
    /// Copying is also a successful recovery action, so it acknowledges that
    /// record's persistent not-pasted reminder without changing its badge.
    @discardableResult
    public func copyToClipboard(_ record: TranscriptRecord) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(record.text, forType: .string)
        if copied, record.outcome == .insertionUnverified {
            updateOutcome(id: record.id, to: .insertionUnverifiedAcknowledged)
        }
        return copied
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([TranscriptRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        // Atomic: a crash mid-write must not corrupt the whole history.
        try? data.write(to: fileURL, options: .atomic)
        // After the write, never before — the atomic rename above replaces
        // the file, and with it any mode already set on the old one.
        PrivateFiles.protectWrittenFile(fileURL)
    }
}

#if canImport(AppKit)
import AppKit
#endif
