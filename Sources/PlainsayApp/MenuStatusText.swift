import AppKit
import SwiftUI
import PlainsayCore

extension MenuContent {
    @ViewBuilder
    func statusHeader(at now: Date) -> some View {
        Text(statusLine(at: now))
        switch modelRecoveryAction(at: now) {
        case .retry:
            Button(Localization.appString("menu.retryModel", fallback: "Try Loading Model Again")) {
                Task { await coordinator.retryModel() }
            }
        case .restart:
            Button(Localization.appString("menu.restartModel", fallback: "Restart Plainsay to Retry")) {
                restartPlainsay()
            }
        case nil:
            EmptyView()
        }
    }

    /// One line that answers "can I dictate right now?"
    private func statusLine(at now: Date) -> String {
        switch coordinator.phase {
        case .recording:
            switch coordinator.recordingStyle {
            case .releaseToFinish:
                return Localization.appString(
                    "menu.status.listeningRelease", fallback: "Listening — release to finish; Esc cancels"
                )
            case .tapToFinish:
                return Localization.appString(
                    "menu.status.listeningTap", fallback: "Listening — tap again to finish; Esc cancels"
                )
            case nil:
                return Localization.appString("menu.status.listening", fallback: "Listening — Esc cancels")
            }
        case .recordingLimitReached:
            return Localization.appString(
                "menu.status.recordingLimitReached",
                fallback: "10-minute limit reached — processing captured audio"
            )
        case .transcribing:
            return Localization.appString("menu.status.transcribing", fallback: "Transcribing…")
        case .cleaning:
            return Localization.appString("menu.status.polishing", fallback: "Polishing transcript…")
        case .modelLoading:
            return modelStatusLine(at: now)
        case .insertedRaw:
            return Localization.appString("menu.status.insertedRaw", fallback: "Inserted without Polishing")
        case .savedToClipboard(.nothingFocused):
            return Localization.appString(
                "menu.status.savedToClipboard", fallback: "Not pasted — dictation saved to the clipboard"
            )
        case .savedToClipboard(.targetGone):
            return Localization.appString(
                "menu.status.savedToClipboardTargetGone",
                fallback: "Not pasted — the window you dictated into was gone"
            )
        case .copied:
            return Localization.appString("menu.status.copied", fallback: "Copied — this app’s profile does not paste")
        case .cancelled:
            return Localization.appString("menu.status.cancelled", fallback: "Dictation cancelled")
        case .error(let message):
            return Localization.appFormat("menu.status.error", fallback: "Not ready — %@", message)
        case .idle:
            break
        }

        // A live load is the information someone needs right now. Keep older
        // recoverable notices in memory, but do not let them hide the model
        // timer or its watchdog while a new attempt is moving forward.
        switch coordinator.modelState {
        case .downloading, .loading:
            return modelStatusLine(at: now)
        case .idle, .ready, .failed:
            break
        }

        // The voice-filter model is a second, independent download, and it is
        // the one someone has just triggered by recording a voice sample. It
        // gets the same treatment: a named stage with a number, never a bare
        // animation.
        if voiceEnrollment.isPreparingModel {
            return voiceStatusLine(at: now)
        }

        if let message = coordinator.lastErrorMessage {
            return Localization.appFormat("menu.status.lastError", fallback: "Last issue — %@", message)
        }

        if coordinator.lastInsertionNeedsManualPaste {
            return Localization.appString(
                "menu.status.lastNotPasted", fallback: "Last dictation wasn't pasted — it is in History"
            )
        }
        if settings.needsOnboarding, coordinator.modelState == .idle {
            return Localization.appString("menu.status.finishSetup", fallback: "Finish setup to start dictation")
        }

        if !permissionStatus.allGranted, coordinator.modelState == .ready {
            return Localization.appString(
                "menu.status.grantPermissions", fallback: "Not ready — grant the missing permissions"
            )
        }

        return modelStatusLine(at: now)
    }

    private func voiceStatusLine(at now: Date) -> String {
        let presentation = ModelLoadPresentation(
            state: voiceEnrollment.loadState,
            timing: voiceEnrollment.loadTiming,
            now: now
        )
        let stage = switch voiceEnrollment.loadState {
        case .downloading:
            Localization.appString(
                "menu.status.voiceDownloading", fallback: "Downloading voice recognition model"
            )
        default:
            Localization.appString(
                "menu.status.voicePreparing", fallback: "Preparing voice recognition model"
            )
        }
        guard let summary = presentation.progressSummary else { return stage }
        return "\(stage) · \(summary)"
    }

    private func modelStatusLine(at now: Date) -> String {
        let presentation = ModelLoadPresentation(
            state: coordinator.modelState,
            timing: coordinator.modelLoadTiming,
            now: now
        )

        if let summary = presentation.progressSummary {
            switch presentation.attention {
            case .downloadStalled:
                return Localization.appFormat(
                    "menu.status.downloadStalled", fallback: "Download may be stalled · %@", summary
                )
            case .downloadActionRequired:
                return Localization.appFormat(
                    "menu.status.modelMayBeStuck", fallback: "Speech model may be stuck · %@", summary
                )
            case .firstPreparation, .takingLonger:
                return Localization.appFormat(
                    "menu.status.stillPreparing", fallback: "Still preparing speech model · %@", summary
                )
            case .actionRequired:
                return Localization.appFormat(
                    "menu.status.modelMayBeStuck", fallback: "Speech model may be stuck · %@", summary
                )
            case nil:
                break
            }
        }

        switch coordinator.modelState {
        case .ready:
            let key: String
            switch settings.hotkeyMode {
            case .holdOnly: key = "menu.status.hold"
            case .toggleOnly: key = "menu.status.tap"
            case .hybrid: key = "menu.status.holdOrTap"
            }
            let fallback: String
            switch settings.hotkeyMode {
            case .holdOnly: fallback = "Hold %@ to dictate"
            case .toggleOnly: fallback = "Tap %@ to dictate"
            case .hybrid: fallback = "Hold or tap %@ to dictate"
            }
            return Localization.appFormat(key, fallback: fallback, settings.binding.localizedDisplayName)
        case .downloading(let progress):
            let summary = presentation.progressSummary
                ?? Localization.appFormat("menu.status.percentage", fallback: "%d%%", percentage(progress))
            return Localization.appFormat(
                "menu.status.downloadingSummary", fallback: "Downloading speech model… %@", summary
            )
        case .loading:
            if let summary = presentation.progressSummary {
                return Localization.appFormat(
                    "menu.status.preparingSummary", fallback: "Preparing speech model… %@", summary
                )
            }
            return Localization.appString(
                "menu.status.preparing", fallback: "Preparing speech model for this Mac…"
            )
        case .idle:
            return Localization.appString("menu.status.starting", fallback: "Starting…")
        case .failed:
            return Localization.appString("menu.status.modelFailed", fallback: "Speech model failed to load")
        }
    }

    private func modelRecoveryAction(at now: Date) -> ModelLoadPresentation.RecoveryAction? {
        ModelLoadPresentation(
            state: coordinator.modelState,
            timing: coordinator.modelLoadTiming,
            now: now
        ).recoveryAction
    }

    private func percentage(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 100).rounded())
    }
}
