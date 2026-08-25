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

    /// Default age ceiling. A transcript older than this has outlived the
    /// recovery it exists for: nobody re-pastes last month's dictation.
    public static let defaultMaxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Discard records older than this, alongside the `limit` count cap.
    ///
    /// `PendingAudioStore` already bounds staged audio by age *and* count, and
    /// history follows that shape rather than inventing a second one. Count
    /// alone is not a retention policy: on a machine used a few times a week,
    /// 100 records is a year of everything that was said.
    ///
    /// Nil means no age limit.
    public var maxAge: TimeInterval? {
        didSet {
            guard maxAge != oldValue else { return }
            if pruneExpired() { save() }
        }
    }

    /// Whether dictations are written to disk at all.
    ///
    /// Turning this off is not just "stop appending". Everything already
    /// stored is deleted, because a switch that silently leaves the last 100
    /// dictations on disk tells the user they have cleared something they
    /// have not — which is worse than not offering the switch.
    public private(set) var isEnabled: Bool

    public init(
        limit: Int = 100,
        maxAge: TimeInterval? = TranscriptHistory.defaultMaxAge,
        isEnabled: Bool = true,
        directory: URL? = nil
    ) {
        self.limit = limit
        self.maxAge = maxAge
        self.isEnabled = isEnabled

        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plainsay", isDirectory: true)

        PrivateFiles.makePrivateDirectory(at: base)
        fileURL = base.appendingPathComponent("history.json")

        guard isEnabled else {
            // A build that starts with history off must not leave a file
            // written by an earlier run where it was on.
            purgeFromDisk()
            return
        }
        load()
        // An age limit that only applied to new writes would leave everything
        // recorded before the window existed sitting there for ever.
        if pruneExpired() { save() }
    }

    /// Applies both retention controls at once, from settings.
    ///
    /// Order matters: the age window is set first so that turning history
    /// *on* does not briefly expose records the window should already have
    /// dropped.
    public func applyPolicy(isEnabled: Bool, maxAge: TimeInterval?) {
        self.maxAge = maxAge
        setEnabled(isEnabled)
    }

    /// Turns recording on, or off *and deletes what is already stored*.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard !enabled else { return }
        records = []
        purgeFromDisk()
    }

    /// Removes records past `maxAge`. Returns whether anything went, so
    /// callers only pay for a write when there is something to write.
    @discardableResult
    private func pruneExpired() -> Bool {
        guard let maxAge else { return false }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let surviving = records.filter { $0.date >= cutoff }
        guard surviving.count != records.count else { return false }
        records = surviving
        return true
    }

    private func purgeFromDisk() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public var mostRecent: TranscriptRecord? { records.first }
    public var hasUnacknowledgedInsertion: Bool {
        records.contains { $0.outcome == .insertionUnverified }
    }

    public func add(_ record: TranscriptRecord) {
        guard isEnabled else { return }
        records.insert(record, at: 0)
        pruneExpired()
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
        // Not `save()`: writing an empty array leaves a file on disk that
        // still says "history lives here". Clearing should remove it.
        purgeFromDisk()
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
