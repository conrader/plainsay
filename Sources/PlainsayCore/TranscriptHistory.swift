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

    /// How far `save()` may trust the file it is about to replace.
    ///
    /// - `owned`: absent, read in full, or written by us. Normal behaviour.
    /// - `backedUp`: it did not fully decode, and a verified, private copy
    ///   sits beside it. The copy holds everything, so the live file may be
    ///   replaced — including by an empty history once retention empties it.
    /// - `protected`: it could not be read, or could not be copied. Nothing
    ///   replaces it until it reads again (and is merged) or a copy succeeds —
    ///   the dictations stay in memory for this run rather than costing what
    ///   is on disk.
    enum DiskState: Equatable { case owned, backedUp, protected }
    private(set) var diskState: DiskState = .owned

    /// The last save did not reach disk as promised: it was refused to protect
    /// a file that could not be backed up, or the write or its owner-only
    /// protection failed. Cleared by the next save that succeeds. The records
    /// stay in memory and the next change retries.
    public private(set) var saveFailed = false

    /// The part of `saveFailed` that matters most: the latest records never
    /// reached disk at all (refused or unwritten, not merely unprotected), so
    /// for now they exist only in memory and are gone if the app quits.
    public private(set) var unsavedInMemory = false

    /// Something that should have been deleted — by Clear, the off switch, or
    /// the age window — may still be on disk. `retryDeletion()` retries it, as
    /// do Clear, turning history off again, and every retention pass.
    public var deletionFailed: Bool { purgeFailed || retentionFailed || expiredOnDisk }
    /// Clear or the off switch did not remove everything.
    private var purgeFailed = false
    /// The last pass over the backups and stages left something behind.
    private var retentionFailed = false
    /// The age window dropped records the live file still holds: set when it
    /// does, cleared once the file has been replaced. Still set after a save
    /// means the save failed, and the next save or retention pass retries.
    private var expiredOnDisk = false

    private let now: () -> Date
    private let backUp: (URL, Data, Date) -> URL?
    private let protectBackup: (URL) -> Bool

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

    public convenience init(
        limit: Int = 100,
        maxAge: TimeInterval? = TranscriptHistory.defaultMaxAge,
        isEnabled: Bool = true,
        directory: URL? = nil
    ) {
        self.init(limit: limit, maxAge: maxAge, isEnabled: isEnabled, directory: directory,
                  now: { Date() }, backUp: { HistoryFile.backUp($0, original: $1, now: $2) })
    }

    /// Seams for tests: the clock (backup names and the age window), a
    /// backup that can be made to fail, and protection of kept backups
    /// during retention, which cannot fail off macOS.
    init(
        limit: Int,
        maxAge: TimeInterval?,
        isEnabled: Bool,
        directory: URL?,
        now: @escaping () -> Date,
        backUp: @escaping (URL, Data, Date) -> URL?,
        protectBackup: @escaping (URL) -> Bool = { HistoryFile.makePrivate($0) }
    ) {
        self.limit = limit
        self.maxAge = maxAge
        self.isEnabled = isEnabled
        self.now = now
        self.backUp = backUp
        self.protectBackup = protectBackup

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
    @discardableResult
    public func applyPolicy(isEnabled: Bool, maxAge: TimeInterval?) -> Bool {
        self.maxAge = maxAge
        let toggled = setEnabled(isEnabled)
        return toggled && !deletionFailed
    }

    /// Turns recording on, or off *and deletes what is already stored*.
    ///
    /// Returns false if something stored could not be deleted. Recording
    /// stops regardless, and turning it off again retries the deletion.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled != isEnabled || (!enabled && purgeFailed) else { return true }
        isEnabled = enabled
        guard !enabled else { return true }
        records = []
        return purgeFromDisk()
    }

    /// Removes records past `maxAge`. Returns whether anything went, so
    /// callers only pay for a write when there is something to write.
    ///
    /// The window covers the `.damaged-*` backups too: they hold the same
    /// transcripts, and "Delete after" must not have an exception nobody sees.
    /// Abandoned staging files are swept, and every kept backup's privacy is
    /// re-verified, on every pass, window or not.
    @discardableResult
    private func pruneExpired() -> Bool {
        let cutoff = maxAge.map { now().addingTimeInterval(-$0) }
        let backups = HistoryFile.applyRetention(toBackupsOf: fileURL, cutoff: cutoff, protect: protectBackup)
        retentionFailed = backups.failed
        if backups.failed {
            Log.history.error("expired or stray history copies could not all be deleted")
        }
        if let cutoff {
            let surviving = records.filter { $0.date >= cutoff }
            // A damaged live file still holds what its backup just lost.
            // Rewrite it from what survived; the backup keeps the unexpired
            // rest, including whatever could not be dated.
            if surviving.count != records.count || (backups.changed && diskState == .backedUp) {
                expiredOnDisk = true
            }
            records = surviving
        }
        return expiredOnDisk
    }

    /// Explicit user intent — clear, or turn history off — so this removes
    /// `history.json` whatever state it is in, and every `.damaged-*` backup
    /// with it: the UI says what was saved has been deleted, and a copy left
    /// beside it would make that untrue. Returns whether all of it is gone.
    @discardableResult
    private func purgeFromDisk() -> Bool {
        let removed = HistoryFile.removeWithBackups(fileURL)
        // Whatever is left was deleted by the user: it is not protected, and
        // must never be read back and merged. The next save replaces it.
        diskState = .owned
        purgeFailed = !removed
        // A purge supersedes every narrower failure: it covers all of it, and
        // there is nothing left in memory waiting to be saved.
        retentionFailed = false
        expiredOnDisk = false
        saveFailed = false
        unsavedInMemory = false
        if !removed {
            Log.history.error("history could not be fully deleted; it will be retried")
        }
        return removed
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

    /// A verified correction updates the copyable text while preserving the
    /// original speech transcript and the user's existing retention policy.
    public func updateCorrectedText(id: UUID, text: String) {
        guard isEnabled, let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[index]
        records[index] = TranscriptRecord(id: record.id, date: record.date, text: text,
            rawText: record.rawText, outcome: record.outcome,
            durationSeconds: record.durationSeconds, targetApp: record.targetApp)
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

    /// Returns false if something stored could not be deleted; calling it
    /// again retries.
    @discardableResult
    public func clear() -> Bool {
        records = []
        // Not `save()`: writing an empty array leaves a file on disk that
        // still says "history lives here". Clearing should remove it.
        return purgeFromDisk()
    }

    /// Retries whatever deletion `deletionFailed` reports. Returns whether
    /// nothing that should be gone is left.
    ///
    /// With history off, or nothing recorded since a failed Clear, that is
    /// the whole purge again. Otherwise the live file now holds only what was
    /// recorded since, so the copies are removed and the live file rewritten —
    /// never deleting what the user has not.
    @discardableResult
    public func retryDeletion() -> Bool {
        if !isEnabled || (purgeFailed && records.isEmpty) {
            return purgeFromDisk()
        }
        if purgeFailed {
            let copiesGone = HistoryFile.removeCopies(of: fileURL)
            save()
            purgeFailed = !copiesGone || saveFailed
        }
        if pruneExpired() { save() }
        return !deletionFailed
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
        switch HistoryFile.load(from: fileURL) {
        case .missing:
            diskState = .owned
        case .clean(let stored):
            records = stored
            diskState = .owned
        case .damaged(let recovered, let original):
            // Show what survived; keep the whole original beside it as a copy.
            records = recovered
            let copy = backUp(fileURL, original, now())
            diskState = copy == nil ? .protected : .backedUp
            let backupName = copy?.lastPathComponent ?? "FAILED; file left untouched"
            Log.history.error("history.json did not fully decode; recovered \(recovered.count, privacy: .public) record(s); backup: \(backupName, privacy: .public)")
        case .unreadable:
            diskState = .protected
            Log.history.error("history.json exists but could not be read; it will not be replaced")
        }
    }

    /// Whether `save()` may replace the file now. A protected file gets
    /// another chance at a backup each time, so a transient failure (a full
    /// disk, a permission since fixed) does not block history for the run.
    private func mayReplaceFile() -> Bool {
        guard diskState == .protected else { return true }
        switch HistoryFile.load(from: fileURL) {
        case .missing:
            diskState = .owned
        case .unreadable:
            return false
        case .clean(let stored):
            // Readable now: what is in it joins this run's records, so
            // replacing the file costs nothing that decodes.
            adopt(stored)
            diskState = .owned
        case .damaged(let recovered, let original):
            guard backUp(fileURL, original, now()) != nil else { return false }
            adopt(recovered)
            diskState = .backedUp
            // This copy did not exist during the caller's retention pass.
            // Sweep it before save can report success; a failed trim or
            // protection check must survive the successful live-file write.
            pruneExpired()
        }
        return true
    }

    /// Folds records read late — the file could not be read at launch — into
    /// this run's, by id. This run's version of a record wins (it may have
    /// been updated since), the order is newest first, and the age and count
    /// limits apply as they would have at launch.
    private func adopt(_ stored: [TranscriptRecord]) {
        let known = Set(records.map(\.id))
        var merged = records + stored.filter { !known.contains($0.id) }
        merged = merged.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .map(\.element)
        if let maxAge {
            let cutoff = now().addingTimeInterval(-maxAge)
            merged.removeAll { $0.date < cutoff }
        }
        if merged.count > limit { merged.removeLast(merged.count - limit) }
        records = merged
    }

    private func save() {
        // Never let any history — an empty one least of all — stand in for a
        // file this run could not read: that is exactly the wipe this guards
        // against. `mayReplaceFile` only allows it once the file has been read
        // and merged, or copied. (`clear()` and the off switch delete on
        // purpose, through `purgeFromDisk`.)
        guard mayReplaceFile() else {
            saveFailed = true
            unsavedInMemory = true
            Log.history.error("history not saved: the existing file could not be read or backed up")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(records)
        } catch {
            saveFailed = true
            unsavedInMemory = true
            Log.history.error("history not saved: encoding failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // All or nothing: a crash mid-write must not corrupt the whole
        // history, a failed write leaves the previous file as it was, and the
        // staging copy is one Clear and retention can find.
        guard HistoryFile.replace(fileURL, with: data) else {
            saveFailed = true
            unsavedInMemory = true
            Log.history.error("history save failed: the file could not be written")
            return
        }
        diskState = .owned
        expiredOnDisk = false
        unsavedInMemory = false
        // Checked on the file now in place: the rename replaced the old one,
        // and with it any mode or exclusion already set on it.
        saveFailed = !PrivateFiles.protectWrittenFile(fileURL)
        if saveFailed {
            Log.history.error("history saved, but could not be made owner-only and excluded from backups")
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
