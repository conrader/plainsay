import AppKit
import CoreGraphics
import XCTest
@testable import PlainsayApp

final class HUDControllerTests: XCTestCase {
    @MainActor
    func testPanelCanJoinOtherAppsWithoutActivating() async throws {
        guard CGSessionCopyCurrentDictionary() != nil else {
            throw XCTSkip("Panel construction requires a WindowServer session")
        }
        _ = NSApplication.shared
        let panel = HUDController.makePanel(contentView: NSView())

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(
            [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        ))
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
    }

    func testFocusedFullscreenWindowTakesPriorityOverMouseOnPrimaryDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let upper = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let fullscreen = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(
            HUDController.screenIndex(
                screenFrames: [primary, upper], focusedFrame: fullscreen,
                mouseLocation: CGPoint(x: 100, y: 100)
            ),
            1
        )
    }

    func testSpanningWindowUsesDisplayWithLargestOverlap() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: -600, y: 100, width: 800, height: 600)
        XCTAssertEqual(
            HUDController.screenIndex(
                screenFrames: [primary, left], focusedFrame: window,
                mouseLocation: CGPoint(x: 100, y: 100)
            ),
            1
        )
    }

    func testFallsBackToMouseWithoutAnOnscreenFocusedWindow() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let offscreen = CGRect(x: -2000, y: 0, width: 800, height: 600)
        for focusedFrame in [nil, offscreen] {
            XCTAssertEqual(
                HUDController.screenIndex(
                    screenFrames: [primary, right], focusedFrame: focusedFrame,
                    mouseLocation: CGPoint(x: 1500, y: 100)
                ),
                1
            )
        }
    }
}
