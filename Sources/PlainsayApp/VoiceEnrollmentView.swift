import SwiftUI
import PlainsayCore

/// Lets someone teach Plainsay their own voice, then filter dictations down
/// to it. Shared between Settings and the Setup Assistant — both just need a
/// `PlainsaySettings` to write the enrolled embedding into.
///
/// The enrollment object is owned by `AppModel`, not by this view. A download
/// started here has to remain observable after the window that started it goes
/// away — including from the menu bar, which is where someone looks first when
/// they are wondering whether the app is doing anything at all.
struct VoiceEnrollmentView: View {
    @Bindable var settings: PlainsaySettings
    let enrollment: VoiceEnrollment
    @State private var secondsRemaining = 0
    @State private var errorMessage: String?
    @State private var recordTask: Task<Void, Never>?

    /// Long enough for a couple of natural sentences, short enough that
    /// nobody has to think about what to say.
    private static let sampleSeconds = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                Localization.appString(
                    "voice.filterToggle", fallback: "Try to focus on my voice (best effort)"
                ),
                isOn: $settings.voiceFilterEnabled
            )
                .disabled(settings.voiceEmbedding == nil)
                .font(.callout)

            if enrollment.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(
                        Localization.appFormat(
                            "voice.recordingCountdown", fallback: "Recording — keep talking for %ds…",
                            secondsRemaining
                        )
                    )
                }
                .font(.callout)
            } else {
                HStack(spacing: 10) {
                    Button(
                        settings.voiceEmbedding == nil
                            ? Localization.appString("voice.recordButton", fallback: "Record my voice…")
                            : Localization.appString("voice.reRecordButton", fallback: "Re-record my voice…")
                    ) {
                        record()
                    }
                    if settings.voiceEmbedding != nil {
                        Label("Voice sample saved", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            if enrollment.loadState != .idle, enrollment.loadState != .ready {
                ModelLoadStatusView(
                    state: enrollment.loadState,
                    timing: enrollment.loadTiming,
                    subject: .voice,
                    onRetry: { record() }
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(
                Localization.appString(
                    "voice.filterDetail",
                    fallback: "Speak a sentence or two on your own so Plainsay can try to focus on your voice. The sample stays on this Mac. Enabling filtering downloads a separate local model. If filtering is unavailable or fails, dictation continues with unfiltered audio; Cloud or bring-your-own-provider modes may then send that audio to the selected service."
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear {
            recordTask?.cancel()
            if enrollment.isRecording { enrollment.cancel() }
        }
    }

    private func record() {
        errorMessage = nil
        recordTask?.cancel()
        recordTask = Task {
            do {
                try await enrollment.prepare()
                try enrollment.start()
                secondsRemaining = Self.sampleSeconds
                for _ in 0..<Self.sampleSeconds {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(1))
                    secondsRemaining -= 1
                }
                if let embedding = try await enrollment.stopAndExtractEmbedding() {
                    settings.voiceEmbedding = embedding
                    settings.voiceFilterEnabled = true
                } else {
                    errorMessage = Localization.appString(
                        "voice.tooQuiet", fallback: "That was too quiet or too short — try again and speak clearly."
                    )
                }
            } catch is CancellationError {
                enrollment.cancel()
            } catch {
                enrollment.cancel()
                errorMessage = error.localizedDescription
            }
        }
    }
}
