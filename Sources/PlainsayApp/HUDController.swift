import AppKit
import Observation
import SwiftUI
import PlainsayCore

/// Hosts the HUD in a floating panel and shows or hides it as the pipeline runs.
///
/// The panel is deliberately inert: if it ever took focus, the app you were
/// typing into would resign first responder and the paste would land nowhere.
@MainActor
final class HUDController {
    private let coordinator: DictationCoordinator
    private var panel: NSPanel?
    private var observationTask: Task<Void, Never>?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        observePhase()
    }

    func stop() {
        observationTask?.cancel()
        hide()
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.hudWidth + 48, height: Metrics.hudHeight + 48),
            // `.nonactivatingPanel` is the load-bearing flag here.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Belt and braces: even ordered front, this panel must never become key.
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = NSHostingView(rootView: HUDHost(coordinator: coordinator))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        return panel
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        position(panel)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: we want it
        // visible without touching the responder chain.
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        // Follow the screen the user is actually working on, not the main one.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        panel.setContentSize(NSSize(
            width: Metrics.hudWidth + 48,
            height: panel.contentView?.fittingSize.height ?? Metrics.hudHeight + 48
        ))

        let frame = panel.frame
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + Metrics.hudBottomInset - 24
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Observation

    /// Re-arms itself after every change; `withObservationTracking` fires once.
    private func observePhase() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let phase = withObservationTracking {
                    self.coordinator.phase
                } onChange: {
                    // Intentionally empty: we re-read on the next loop pass.
                }
                self.apply(phase)
                await self.waitForPhaseChange()
            }
        }
    }

    private func waitForPhaseChange() async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = coordinator.phase
            } onChange: {
                continuation.resume()
            }
        }
    }

    private func apply(_ phase: DictationCoordinator.Phase) {
        switch phase {
        case .idle:
            hide()
        case .recording, .transcribing, .cleaning, .modelLoading, .insertedRaw, .error:
            show()
            // Error text changes the panel's height.
            if let panel { position(panel) }
        }
    }
}
