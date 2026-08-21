import SwiftUI
import PlainsayCore

/// Every dictation, newest first.
///
/// This is the recovery path for the failure the app cannot prevent: a paste
/// that silently doesn't land. The text is written here before insertion is
/// attempted, so it is always retrievable even when the paste vanished.
struct HistoryView: View {
    let history: TranscriptHistory
    @State private var query = ""
    @State private var copiedID: UUID?

    private var filtered: [TranscriptRecord] {
        let all = history.records.filter { !$0.text.isEmpty }
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if history.records.isEmpty {
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
                        history.clear()
                    }
                }
                .padding(12)
            }
        }
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
