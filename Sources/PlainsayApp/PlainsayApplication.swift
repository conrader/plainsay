import AppKit
import SwiftUI
import PlainsayCore

@main
struct PlainsayApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                updates: model.updates,
                coordinator: model.coordinator,
                settings: model.settings,
                permissionStatus: model.permissionStatus
            )
        } label: {
            MenuBarIcon(
                coordinator: model.coordinator,
                settings: model.settings,
                permissionStatus: model.permissionStatus
            )
        }
    }
}

/// The menu bar glyph doubles as the always-visible state light: filled while
/// listening, hollow at rest, struck through when something needs attention.
private struct MenuBarIcon: View {
    let coordinator: DictationCoordinator
    let settings: PlainsaySettings
    let permissionStatus: PermissionStatus

    var body: some View {
        // Do not put a periodically-updating TimelineView in a MenuBarExtra
        // label. On macOS 26 it can enter a continuous render loop while the
        // model is loading, consuming a full core and unbounded memory. The
        // icon itself only changes when observable coordinator state changes;
        // an elapsed-time snapshot is sufficient for its help text.
        icon(at: Date())
    }

    private func icon(at now: Date) -> some View {
        Group {
            // The brand mark replaces the plain "waveform" glyph for the one
            // state most people see the most: ready and idle. Every other
            // state (recording, working, error, unavailable) keeps its
            // existing SF Symbol — those already carry meaning through shape
            // alone, which a single static mark can't add to.
            if symbol == "waveform" {
                TrayMarkView()
            } else {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .accessibilityLabel(accessibilityLabel(at: now))
        .help(accessibilityLabel(at: now))
    }

    private var symbol: String {
        switch coordinator.phase {
        case .recording: "waveform.circle.fill"
        case .recordingLimitReached, .transcribing, .cleaning, .modelLoading: "waveform.circle"
        case .error: "waveform.slash"
        case .insertedRaw, .savedToClipboard, .cancelled: canDictate ? "waveform" : unavailableSymbol
        case .idle:
            canDictate ? "waveform" : unavailableSymbol
        }
    }

    private var unavailableSymbol: String {
        switch coordinator.modelState {
        case .downloading, .loading: "waveform.circle"
        case .failed, .idle, .ready: "waveform.slash"
        }
    }

    private var canDictate: Bool {
        coordinator.isReadyForDictation && permissionStatus.allGranted
    }

    private func accessibilityLabel(at now: Date) -> String {
        switch coordinator.phase {
        case .recording: Localization.appString("menu.a11y.listening", fallback: "Plainsay is listening")
        case .recordingLimitReached:
            Localization.appString(
                "menu.a11y.recordingLimitReached",
                fallback: "Plainsay reached the ten-minute recording limit and is processing the captured audio"
            )
        case .transcribing: Localization.appString("menu.a11y.transcribing", fallback: "Plainsay is transcribing")
        case .cleaning: Localization.appString("menu.a11y.polishing", fallback: "Plainsay is polishing the transcript")
        case .modelLoading: modelAccessibilityLabel(at: now)
        case .error(let message):
            Localization.appFormat("menu.a11y.error", fallback: "Plainsay error: %@", message)
        case .insertedRaw:
            Localization.appString("menu.a11y.insertedRaw", fallback: "Plainsay inserted an unpolished transcript")
        case .savedToClipboard:
            Localization.appString(
                "menu.a11y.savedToClipboard",
                fallback: "Plainsay saved the dictation to the clipboard — nothing was focused to paste into"
            )
        case .cancelled:
            Localization.appString("menu.a11y.cancelled", fallback: "Plainsay cancelled the dictation")
        case .idle: readinessAccessibilityLabel(at: now)
        }
    }

    private func readinessAccessibilityLabel(at now: Date) -> String {
        if canDictate {
            return Localization.appString("menu.a11y.ready", fallback: "Plainsay is ready")
        }
        if settings.needsOnboarding {
            return Localization.appString(
                "menu.a11y.setupIncomplete", fallback: "Plainsay is not ready; setup is incomplete"
            )
        }
        if !permissionStatus.allGranted {
            let missing = permissionStatus.missing.map(\.title).joined(separator: ", ")
            return Localization.appFormat(
                "menu.a11y.missingPermissions", fallback: "Plainsay is not ready; missing permissions: %@", missing
            )
        }
        return modelAccessibilityLabel(at: now)
    }

    private func modelAccessibilityLabel(at now: Date) -> String {
        let base = switch coordinator.modelState {
        case .ready:
            Localization.appString("menu.a11y.ready", fallback: "Plainsay is ready")
        case .idle:
            Localization.appString("menu.a11y.notReady", fallback: "Plainsay is not ready")
        case .downloading:
            Localization.appString("modelStatus.a11y.downloading", fallback: "Downloading speech model")
        case .loading:
            Localization.appString("menu.a11y.preparing", fallback: "Plainsay is preparing the speech model")
        case .failed:
            Localization.appString(
                "menu.a11y.modelFailed", fallback: "Plainsay is not ready because the speech model failed to load"
            )
        }

        let presentation = ModelLoadPresentation(
            state: coordinator.modelState,
            timing: coordinator.modelLoadTiming,
            now: now
        )
        return [base, presentation.accessibilityProgress, presentation.attentionMessage]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

struct MenuContent: View {
    let updates: UpdateController
    let coordinator: DictationCoordinator
    let settings: PlainsaySettings
    let permissionStatus: PermissionStatus

    /// Languages offered as translation targets: the ones the speaker listed,
    /// plus English, which is the overwhelmingly common target and is often
    /// not something people list as a language they *speak*.
    private var translationTargets: [String] {
        var codes = settings.spokenLanguages.map(SupportedLanguage.primaryCode)
        if !codes.contains("en") { codes.append("en") }
        return codes
    }

    private var isEntitled: Bool { coordinator.cloud.account?.isActive == true }

    /// Translation lives in the menu bar rather than in Settings because it is
    /// switched per conversation, not configured once — the whole point is
    /// reaching it without leaving what you are writing.
    @ViewBuilder
    private var translationMenu: some View {
        if isEntitled {
            Menu(translationMenuTitle) {
                ForEach(translationTargets, id: \.self) { code in
                    Button {
                        // Picking a language *is* switching translation on.
                        // A separate on/off switch beside a language list is
                        // one control too many for something reached mid-task.
                        settings.translationTargetLanguage = code
                    } label: {
                        if settings.translationTargetLanguage == code {
                            Label(SupportedLanguage.named(code), systemImage: "checkmark")
                        } else {
                            Text(SupportedLanguage.named(code))
                        }
                    }
                }
                Divider()
                Button(Localization.appString("menu.translate.off", fallback: "Don't translate")) {
                    settings.translationTargetLanguage = nil
                }

                Divider()
                // The chord is a system-wide event tap, not a menu shortcut, so
                // SwiftUI cannot display it next to an item. Naming it here is
                // the only way it is ever discovered.
                Text(
                    Localization.appFormat(
                        "menu.translate.shortcut",
                        fallback: "%@ toggles translation anywhere",
                        TranslationHotkey.controlOptionCommandT.displayName
                    )
                )
            }
        } else {
            // Shown, not hidden: a feature nobody can see is a feature nobody
            // subscribes for. Disabled with the reason, so it does not read as
            // something broken.
            Button(Localization.appString("menu.translate.locked", fallback: "Translate — needs Plainsay Cloud")) {}
                .disabled(true)
        }
    }

    private var translationMenuTitle: String {
        guard let target = settings.translationTargetLanguage else {
            return Localization.appString("menu.translate.idle", fallback: "Translate")
        }
        return Localization.appFormat(
            "menu.translate.active", fallback: "Translating → %@", SupportedLanguage.named(target)
        )
    }

    var body: some View {
        Group {
            // MenuBarExtra menus share the same fragile hosting path as their
            // labels. Refresh the elapsed value whenever the menu is rendered
            // instead of installing a repeating timeline inside the menu.
            statusHeader(at: Date())

            if !permissionStatus.allGranted {
                Divider()
                Text(
                    Localization.appFormat(
                        "menu.missingPermissions", fallback: "Missing permissions: %@",
                        permissionStatus.missing.map(\.title).joined(separator: ", ")
                    )
                )
                Button(fixPermissionsTitle) {
                    if settings.needsOnboarding {
                        openSetupAssistant()
                    } else {
                        openSettings()
                    }
                }
            }

            Divider()

            translationMenu

            Divider()

            // The recovery path when a paste didn't land: get the words back
            // without hunting through Settings.
            if let last = coordinator.history.records.first(where: { !$0.text.isEmpty }) {
                Button("Copy last dictation") {
                    coordinator.history.copyToClipboard(last)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }

            if coordinator.lastErrorMessage != nil || coordinator.lastInsertionNeedsManualPaste {
                Button(Localization.appString("menu.dismissIssue", fallback: "Dismiss Last Notice")) {
                    coordinator.dismissLastIssue()
                }
            }

            // Distributed outside the App Store, so nothing updates this app but
            // this menu item and the scheduled check behind it.
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheck)

            if settings.needsOnboarding {
                Button("Finish Setup…") {
                    openSetupAssistant()
                }
            }

            Divider()

            Button(Localization.appString("menu.starOnGitHub", fallback: "Star Plainsay on GitHub…")) {
                if let url = URL(string: "https://github.com/conrader/plainsay") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit Plainsay") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .environment(\.locale, Locale(identifier: Localization.resolvedCode(override: settings.interfaceLanguage)))
    }

    private var fixPermissionsTitle: String {
        settings.needsOnboarding
            ? Localization.appString("menu.continueSetup", fallback: "Continue Setup…")
            : Localization.appString("menu.fixInSettings", fallback: "Fix in Settings…")
    }

    @ViewBuilder
    private func statusHeader(at now: Date) -> some View {
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
        case .savedToClipboard:
            return Localization.appString(
                "menu.status.savedToClipboard", fallback: "Not pasted — dictation saved to the clipboard"
            )
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

/// Core ML model preparation is not reliably cancellation-aware. Once the
/// watchdog says it may be stuck, a process restart is the only honest retry:
/// queue a tiny helper that waits for this process to exit, then reopens the
/// exact app bundle. The helper receives paths as positional arguments so no
/// user-controlled string is interpreted as shell code.
@MainActor
func restartPlainsay() {
    let bundleURL = Bundle.main.bundleURL
    guard bundleURL.pathExtension == "app" else {
        NSSound.beep()
        return
    }

    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = [
        "-c",
        "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
        "plainsay-relauncher",
        String(ProcessInfo.processInfo.processIdentifier),
        bundleURL.path,
    ]
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice

    do {
        try helper.run()
        NSApp.terminate(nil)
    } catch {
        NSSound.beep()
    }
}
