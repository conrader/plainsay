import SwiftUI
import PlainsayCore

/// One presentation of model readiness used wherever someone can reasonably
/// wonder whether dictation is available yet.
struct ModelLoadStatusView: View {
    let state: SpeechModelLoadState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                statusLabel
                Spacer(minLength: 12)
                if let percentage {
                    Text("\(percentage)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.callout)

            if showsProgressBar {
                progressBar
                    .progressViewStyle(.linear)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(accessibilityValue)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state {
        case .idle:
            Label("Not ready", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .downloading:
            Label("Downloading speech model", systemImage: "arrow.down.circle")
        case .loading:
            Label("Preparing model for this Mac", systemImage: "gearshape.2")
        case .ready:
            Label("Ready to dictate", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch state {
        case .downloading(let progress):
            ProgressView(value: normalized(progress))
        case .loading(let progress):
            if let progress {
                ProgressView(value: normalized(progress))
            } else {
                ProgressView()
            }
        case .idle, .ready, .failed:
            EmptyView()
        }
    }

    private var showsProgressBar: Bool {
        switch state {
        case .downloading, .loading: true
        case .idle, .ready, .failed: false
        }
    }

    private var percentage: Int? {
        switch state {
        case .downloading(let progress):
            Int((normalized(progress) * 100).rounded())
        case .loading(let progress):
            progress.map { Int((normalized($0) * 100).rounded()) }
        case .idle, .ready, .failed:
            nil
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .downloading: "Downloading speech model"
        case .loading: "Preparing speech model"
        case .idle: "Speech model not ready"
        case .ready: "Speech model ready"
        case .failed: "Speech model failed to load"
        }
    }

    private var accessibilityValue: String {
        percentage.map { "\($0) percent" } ?? "In progress"
    }

    private func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
