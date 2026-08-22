import SwiftUI
import PlainsayCore

/// Shared, truthful interpretation of model progress. Core ML cannot provide
/// an ETA while it compiles a model, so Plainsay shows elapsed time and only
/// escalates when a phase has stopped moving for an unusually long time.
struct ModelLoadPresentation {
    typealias Attention = SpeechModelLoadWatchdog.Attention
    typealias RecoveryAction = SpeechModelLoadWatchdog.RecoveryAction

    let state: SpeechModelLoadState
    let timing: SpeechModelLoadTiming?
    let now: Date

    private var watchdog: SpeechModelLoadWatchdog {
        SpeechModelLoadWatchdog(state: state, timing: timing, now: now)
    }

    var elapsed: TimeInterval? {
        watchdog.elapsed
    }

    var elapsedText: String? {
        elapsed.map(SpeechModelLoadWatchdog.timecode)
    }

    var percentage: Int? {
        watchdog.percentage
    }

    var progressSummary: String? {
        let parts = [
            percentage.map { Localization.appFormat("modelStatus.percentage", fallback: "%d%%", $0) },
            elapsedText,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Spoken equivalent of the compact visual timecode. Seconds are less
    /// elegant on screen but unambiguous when VoiceOver reads them aloud.
    var accessibilityProgress: String? {
        let elapsedSeconds = elapsed.map { max(0, Int($0)) }
        switch (percentage, elapsedSeconds) {
        case let (.some(percent), .some(seconds)):
            return Localization.appFormat(
                "modelStatus.a11y.percentElapsedSeconds",
                fallback: "%d percent, %d seconds elapsed",
                percent,
                seconds
            )
        case let (.some(percent), nil):
            return Localization.appFormat("modelStatus.a11y.percent", fallback: "%d percent", percent)
        case let (nil, .some(seconds)):
            return Localization.appFormat(
                "modelStatus.a11y.elapsedSeconds",
                fallback: "%d seconds elapsed",
                seconds
            )
        case (nil, nil):
            return nil
        }
    }

    var attention: Attention? {
        watchdog.attention
    }

    var attentionMessage: String? {
        switch attention {
        case .downloadStalled:
            Localization.appString(
                "modelStatus.attention.downloadStalled",
                fallback: "The download has not advanced for a while. Check your connection, then try again."
            )
        case .downloadActionRequired:
            Localization.appString(
                "modelStatus.attention.downloadActionRequired",
                fallback: "The download may be stuck. Restart Plainsay to try again."
            )
        case .firstPreparation:
            Localization.appString(
                "modelStatus.attention.firstPreparation",
                fallback: "Still preparing — first setup can take a few minutes."
            )
        case .takingLonger:
            Localization.appString(
                "modelStatus.attention.takingLonger",
                fallback: "This is taking longer than usual. Plainsay is still working."
            )
        case .actionRequired:
            Localization.appString(
                "modelStatus.attention.actionRequired",
                fallback: "Model preparation may be stuck. Restart Plainsay to try again."
            )
        case nil:
            nil
        }
    }

    var recoveryAction: RecoveryAction? {
        watchdog.recoveryAction
    }
}

/// One presentation of model readiness used wherever someone can reasonably
/// wonder whether dictation is available yet.
struct ModelLoadStatusView: View {
    let state: SpeechModelLoadState
    let timing: SpeechModelLoadTiming?
    let onRetry: (() -> Void)?
    let onRestart: (() -> Void)?

    init(
        state: SpeechModelLoadState,
        timing: SpeechModelLoadTiming? = nil,
        onRetry: (() -> Void)? = nil,
        onRestart: (() -> Void)? = nil
    ) {
        self.state = state
        self.timing = timing
        self.onRetry = onRetry
        self.onRestart = onRestart
    }

    var body: some View {
        Group {
            if timing != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(presentation: ModelLoadPresentation(state: state, timing: timing, now: context.date))
                }
            } else {
                content(presentation: ModelLoadPresentation(state: state, timing: nil, now: Date()))
            }
        }
    }

    private func content(presentation: ModelLoadPresentation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                statusLabel
                Spacer(minLength: 12)
                if let summary = presentation.progressSummary {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.callout)

            if showsProgressBar {
                progressBar
                    .progressViewStyle(.linear)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(accessibilityValue(presentation: presentation))
            }

            if let message = presentation.attentionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(presentation.attention == .firstPreparation ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.recoveryAction == .retry, let onRetry {
                Button(
                    Localization.appString("modelStatus.retry", fallback: "Try Again"),
                    action: onRetry
                )
            }

            if presentation.recoveryAction == .restart, let onRestart {
                Button(
                    Localization.appString("modelStatus.restart", fallback: "Restart Plainsay"),
                    action: onRestart
                )
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
            ProgressView(value: SpeechModelLoadState.clampedProgress(progress))
        case .loading(let progress):
            if let progress {
                ProgressView(value: SpeechModelLoadState.clampedProgress(progress))
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

    private var accessibilityLabel: String {
        switch state {
        case .downloading:
            Localization.appString("modelStatus.a11y.downloading", fallback: "Downloading speech model")
        case .loading:
            Localization.appString("modelStatus.a11y.preparing", fallback: "Preparing speech model")
        case .idle:
            Localization.appString("modelStatus.a11y.notReady", fallback: "Speech model not ready")
        case .ready:
            Localization.appString("modelStatus.a11y.ready", fallback: "Speech model ready")
        case .failed:
            Localization.appString("modelStatus.a11y.failed", fallback: "Speech model failed to load")
        }
    }

    private func accessibilityValue(presentation: ModelLoadPresentation) -> String {
        presentation.accessibilityProgress
            ?? Localization.appString("modelStatus.a11y.inProgress", fallback: "In progress")
    }
}
