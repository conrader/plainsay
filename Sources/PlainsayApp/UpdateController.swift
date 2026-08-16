import Observation
import PlainsayCore
import Sparkle
import SwiftUI

/// Software updates, via Sparkle.
///
/// Plainsay is distributed outside the App Store, so nothing updates it unless
/// the app does it itself. Without this, a fix ships and the people running the
/// broken build never hear about it.
@MainActor
@Observable
final class UpdateController {
    private let updater: SPUStandardUpdaterController

    /// Mirrors Sparkle's own gate so the menu item can disable itself while a
    /// check is already running.
    private(set) var canCheck = true

    init() {
        // `startingUpdater: true` begins the scheduled-check timer. Whether it
        // actually checks is governed by SUEnableAutomaticChecks in Info.plist,
        // which is false until the user opts in — Sparkle asks on first run.
        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observeCanCheck()
    }

    /// The user asked. Always shows UI, including "you're up to date".
    func checkForUpdates() {
        updater.updater.checkForUpdates()
    }

    var automaticallyChecks: Bool {
        get { updater.updater.automaticallyChecksForUpdates }
        set { updater.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Human-readable time of the last check, for the settings screen.
    var lastCheckDescription: String {
        guard let date = updater.updater.lastUpdateCheckDate else {
            return Localization.appString("updates.never", fallback: "Never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func observeCanCheck() {
        // Sparkle exposes this as KVO rather than a publisher.
        withObservationTracking {
            _ = canCheck
        } onChange: { }

        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let value = updater.updater.canCheckForUpdates
                if value != canCheck { canCheck = value }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
