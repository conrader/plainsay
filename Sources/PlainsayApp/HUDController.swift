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
    private var spaceObserver: NSObjectProtocol?
    private var observationTask: Task<Void, Never>?
    /// Only running while `.recording`: the live preview grows the panel by a
    /// second line without changing `phase`, so it needs its own trigger to
    /// resize the panel.
    private var previewObservationTask: Task<Void, Never>?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        observePhase()
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.activeSpaceChanged() }
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        previewObservationTask?.cancel()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        hide()
    }

    // MARK: - Panel

    static func makePanel(contentView: NSView) -> NSPanel {
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
        // Cross-app fullscreen Spaces require the overlay collection behavior.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        // Belt and braces: even ordered front, this panel must never become key.
        panel.becomesKeyOnlyIfNeeded = true

        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView

        return panel
    }

    private func show() {
        // AppKit can leave an ordered panel on the Space it was shown on.
        if let panel, !panel.isOnActiveSpace { hide() }
        let panel = self.panel ?? Self.makePanel(
            contentView: NSHostingView(rootView: HUDHost(coordinator: coordinator))
        )
        self.panel = panel

        position(panel, on: workingScreen())
        // Order the HUD while the dictation target keeps keyboard focus.
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        // Give the next presentation a fresh WindowServer window.
        panel = nil
    }

    private func activeSpaceChanged() {
        guard panel != nil else { return }
        show()
    }

    private static let accessibilityTimeout: Float = 0.25

    private func workingScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return screens.first }
        // Runs on the main thread; bound each AX request so a hung frontmost app
        // falls back to the pointer's display instead of stalling the HUD.
        let focusedFrame = NSWorkspace.shared.frontmostApplication.flatMap {
            FocusedWindow.accessibilityFrame(of: $0, messagingTimeout: Self.accessibilityTimeout)
        }
        let index = Self.screenIndex(
            screenFrames: screens.map(\.frame),
            focusedFrame: focusedFrame,
            mouseLocation: NSEvent.mouseLocation
        )
        return index.map { screens[$0] } ?? NSScreen.main ?? screens.first
    }

    nonisolated static func screenIndex(
        screenFrames: [CGRect], focusedFrame: CGRect?, mouseLocation: CGPoint
    ) -> Int? {
        if let focusedFrame, let primaryFrame = screenFrames.first {
            // Accessibility measures down from the primary screen's top edge.
            var frame = focusedFrame
            frame.origin.y = primaryFrame.maxY - focusedFrame.maxY
            var bestIndex: Int?
            var largestArea: CGFloat = 0
            for (index, screenFrame) in screenFrames.enumerated() {
                let overlap = screenFrame.intersection(frame)
                guard !overlap.isEmpty else { continue }
                let area = overlap.width * overlap.height
                if area > largestArea {
                    bestIndex = index
                    largestArea = area
                }
            }
            if let bestIndex { return bestIndex }
        }
        return screenFrames.firstIndex { $0.contains(mouseLocation) }
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
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
        case .recording, .recordingLimitReached, .transcribing, .cleaning,
             .modelLoading, .insertedRaw, .savedToClipboard, .copied, .cancelled, .error:
            show()
        }

        if phase == .recording {
            observeLivePreview()
        } else {
            previewObservationTask?.cancel()
            previewObservationTask = nil
        }
    }

    /// Repositions/resizes the panel as the live preview line appears and
    /// grows, since none of that changes `phase` itself.
    private func observeLivePreview() {
        guard previewObservationTask == nil else { return }
        previewObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = withObservationTracking {
                    self.coordinator.livePreviewText
                } onChange: {
                    // Intentionally empty: re-read on the next loop pass.
                }
                if let panel = self.panel {
                    self.position(panel, on: panel.screen ?? self.workingScreen())
                }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.coordinator.livePreviewText
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
