import AppKit
import CoreGraphics
import Testing
@testable import PlainsayApp

struct HUDControllerTests {
    @Test(.enabled(if: CGSessionCopyCurrentDictionary() != nil, "Panel construction requires a WindowServer session"))
    @MainActor
    func panelCanJoinOtherAppsWithoutActivating() {
        _ = NSApplication.shared
        let panel = HUDController.makePanel(contentView: NSView())

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.collectionBehavior.contains(
            [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        ))
        #expect(panel.level == .statusBar)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.canBecomeMain)
    }

    @Test func focusedFullscreenWindowTakesPriorityOverMouseOnPrimaryDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let upper = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let fullscreen = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(HUDController.screenIndex(
            screenFrames: [primary, upper], focusedFrame: fullscreen,
            mouseLocation: CGPoint(x: 100, y: 100)
        ) == 1)
    }

    @Test func spanningWindowUsesDisplayWithLargestOverlap() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: -600, y: 100, width: 800, height: 600)
        #expect(HUDController.screenIndex(
            screenFrames: [primary, left], focusedFrame: window,
            mouseLocation: CGPoint(x: 100, y: 100)
        ) == 1)
    }

    @Test(arguments: [nil, CGRect(x: -2000, y: 0, width: 800, height: 600)] as [CGRect?])
    func fallsBackToMouseWithoutAnOnscreenFocusedWindow(focusedFrame: CGRect?) {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(HUDController.screenIndex(
            screenFrames: [primary, right], focusedFrame: focusedFrame,
            mouseLocation: CGPoint(x: 1500, y: 100)
        ) == 1)
    }
}
