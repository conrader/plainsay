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
                permissionStatus: model.permissionStatus,
                voiceEnrollment: model.voiceEnrollment
            )
        } label: {
            MenuBarIcon(
                coordinator: model.coordinator,
                settings: model.settings,
                permissionStatus: model.permissionStatus,
                voiceEnrollment: model.voiceEnrollment
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
    let voiceEnrollment: VoiceEnrollment

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
        .accessibilityLabel(iconLabel(at: now))
        .help(iconLabel(at: now))
    }

    /// The state label, plus whether the next dictation is private.
    private func iconLabel(at now: Date) -> String {
        let base = accessibilityLabel(at: now)
        guard coordinator.privateDictation.isArmed else { return base }
        return base + ", " + Localization.appString("menu.a11y.privateArmed", fallback: "Private dictation armed")
    }

    private var symbol: String {
        switch coordinator.phase {
        case .recording: "waveform.circle.fill"
        case .recordingLimitReached, .transcribing, .cleaning, .modelLoading: "waveform.circle"
        case .error: "waveform.slash"
        case .insertedRaw, .savedToClipboard, .copied, .cancelled: canDictate ? "waveform" : unavailableSymbol
        case .idle:
            canDictate ? "waveform" : unavailableSymbol
        }
    }

    private var unavailableSymbol: String {
        switch coordinator.modelState {
        case .downloading, .loading: "waveform.circle"
        case .failed, .idle, .ready:
            // A voice-filter download is work in progress too. Showing the
            // struck-through "nothing is happening" glyph through it is what
            // made the app look hung from the one place people check first.
            voiceEnrollment.isPreparingModel ? "waveform.circle" : "waveform.slash"
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
        case .savedToClipboard(.nothingFocused):
            Localization.appString(
                "menu.a11y.savedToClipboard",
                fallback: "Plainsay saved the dictation to the clipboard — nothing was focused to paste into"
            )
        case .savedToClipboard(.targetGone):
            // Not the same sentence: telling someone "nothing was focused"
            // when something plainly was, and the dictation was held back on
            // purpose, is wrong information rather than a shorter version of
            // the right one.
            Localization.appString(
                "menu.a11y.savedToClipboardTargetGone",
                fallback: "Plainsay saved the dictation to the clipboard — the window it was meant for could not be brought back"
            )
        case .copied:
            Localization.appString("menu.status.copied", fallback: "Copied — this app’s profile does not paste")
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
        if case .ready = coordinator.modelState, voiceEnrollment.isPreparingModel {
            let voice = ModelLoadPresentation(
                state: voiceEnrollment.loadState,
                timing: voiceEnrollment.loadTiming,
                now: now
            )
            return [
                Localization.appString(
                    "menu.a11y.preparingVoice", fallback: "Plainsay is preparing the voice recognition model"
                ),
                voice.accessibilityProgress,
                voice.attentionMessage,
            ]
                .compactMap { $0 }
                .joined(separator: ". ")
        }

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
    let voiceEnrollment: VoiceEnrollment

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

            privateDictationMenu

            Button(Localization.appString("menu.correctLast", fallback: "Correct last dictation…") + "  ⌃⌥⌘R") {
                AppModel.shared.correctionWindow.show()
            }
            .disabled(
                coordinator.lastDictation == nil || coordinator.phase.isBusy || coordinator.isApplyingCorrection
                    || coordinator.editingRefusal != nil
            )

            Button("Voice Edit…  ⌃⌥⌘E") {
                AppModel.shared.voiceEditWindow.show()
            }
            .disabled(coordinator.phase.isBusy || coordinator.editingRefusal != nil)

            Divider()

            // The recovery path when a paste didn't land: get the words back
            // without hunting through Settings.
            if let last = coordinator.history.records.first(where: { !$0.text.isEmpty }) {
                Button("Copy last dictation") {
                    coordinator.history.copyToClipboard(last)
                }
                .keyboardShortcut(
                    coordinator.privateDictation.ephemeral.hasText ? nil : KeyboardShortcut("c", modifiers: [.command, .shift])
                )
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
