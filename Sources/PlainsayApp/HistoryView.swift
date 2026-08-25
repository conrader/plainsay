import SwiftUI
import PlainsayCore

/// Every dictation, newest first.
///
/// This is the recovery path for the failure the app cannot prevent: a paste
/// that silently doesn't land. The text is written here before insertion is
/// attempted, so it is always retrievable even when the paste vanished.
struct HistoryView: View {
    let history: TranscriptHistory
    @Bindable var settings: PlainsaySettings
    /// Clearing history must also erase the raw staged audio, which the
    /// coordinator owns — hence the callback rather than calling `history.clear()`
    /// directly.
    let onClearAll: () -> Void
    /// Pushes a changed switch or window into the store. Turning history off
    /// deletes what is already saved, so this is not a cosmetic refresh.
    let onPolicyChange: () -> Void
    @State private var query = ""
    @State private var copiedID: UUID?

    /// Offered windows, in days. No "forever": the point of the control is
    /// that transcripts stop accumulating, and an unbounded option would be
    /// the one most people leave selected.
    private static let retentionChoices = [7, 30, 90, 365]

    private var filtered: [TranscriptRecord] {
        let all = history.records.filter { !$0.text.isEmpty }
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls

            if !settings.historyEnabled {
                ContentUnavailableView(
                    "History is off",
                    systemImage: "clock.badge.xmark",
                    description: Text(
                        Localization.appString(
                            "history.disabledDescription",
                            fallback: "Dictations are not being saved, and anything previously saved has been deleted. Plainsay can no longer recover a dictation whose paste silently failed — you would have to say it again."
                        )
                    )
                )
            } else if history.records.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "text.quote",
                    description: Text(
                        Localization.appString(
                            "history.emptyDescription",
                            fallback: "Hold your hotkey and speak. Completed transcripts appear here before Plainsay attempts to insert them, so you can copy one again if needed."
                        )
                    )
                )
            } else {
                List {
                    ForEach(filtered) { record in
                        HistoryRow(
                            record: record,
                            justCopied: copiedID == record.id,
                            onCopy: {
                                history.copyToClipboard(record)
                                copiedID = record.id
                            }
                        )
                    }
                }
                .searchable(text: $query, prompt: "Search dictations")
            }

            if settings.historyEnabled {
                HStack {
                    Text(
                        Localization.appFormat(
                            "history.savedCount", fallback: "%d saved on this Mac", history.records.count
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear history", role: .destructive) {
                        onClearAll()
                    }
                }
                .padding(12)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.historyEnabled) {
                Text("Save dictations on this Mac")
            }
            .onChange(of: settings.historyEnabled) { _, _ in onPolicyChange() }

            if settings.historyEnabled {
                Picker(selection: $settings.historyRetentionDays) {
                    ForEach(Self.retentionChoices, id: \.self) { days in
                        Text(label(forDays: days)).tag(days)
                    }
                } label: {
                    Text("Delete after")
                }
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: settings.historyRetentionDays) { _, _ in onPolicyChange() }
            }

            Text(
                settings.historyEnabled
                    ? Localization.appString(
                        "history.explainerOn",
                        fallback: "Transcripts are stored on this Mac only, readable by your account alone, and excluded from Time Machine. They are kept so a dictation whose paste silently failed is not lost."
                    )
                    : Localization.appString(
                        "history.explainerOff",
                        fallback: "Turning this on starts saving new dictations. It does not bring back anything already deleted."
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func label(forDays days: Int) -> String {
        days == 365
            ? Localization.appString("history.retention.year", fallback: "1 year")
            : Localization.appFormat("history.retention.days", fallback: "%d days", days)
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let justCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.text)
                .lineLimit(4)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(
                    Localization.appFormat(
                        "history.durationSeconds", fallback: "%@s",
                        record.durationSeconds.formatted(.number.precision(.fractionLength(1)))
                    )
                )
                if let app = record.targetApp {
                    Text("·")
                    Text(app.split(separator: ".").last.map(String.init) ?? app)
                }
                if record.outcome == .insertedWithoutCleanup {
                    Text("·")
                    // Worth flagging: this one skipped the cleanup pass.
                    Text("raw").foregroundStyle(.orange)
                }
                if record.outcome == .insertionUnverified
                    || record.outcome == .insertionUnverifiedAcknowledged
                {
                    Text("·")
                    Text(Localization.appString("history.notPasted", fallback: "not pasted"))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(
                    justCopied
                        ? Localization.appString("history.copied", fallback: "Copied")
                        : Localization.appString("history.copy", fallback: "Copy"),
                    action: onCopy
                )
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
