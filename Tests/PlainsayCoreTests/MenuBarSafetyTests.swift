import Foundation
import XCTest

final class MenuBarSafetyTests: XCTestCase {
    /// A periodic TimelineView inside a MenuBarExtra label or menu enters a
    /// continuous render loop on macOS 26.5.1. This source-level guard keeps
    /// that process-wide CPU and memory regression from being reintroduced.
    func testMenuBarExtraDoesNotInstallTimelineView() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // Every file that holds part of the MenuBarExtra hierarchy: the menu
        // sections live in extensions of MenuContent outside the main file.
        let menuBarSources = [
            "Sources/PlainsayApp/PlainsayApplication.swift",
            "Sources/PlainsayApp/MenuSections.swift",
            "Sources/PlainsayApp/MenuStatusText.swift",
        ]
        let timelineConstruction = try NSRegularExpression(pattern: #"\bTimelineView\s*\("#)

        for path in menuBarSources {
            let applicationSource = repositoryRoot.appendingPathComponent(path)
            let source = try String(contentsOf: applicationSource, encoding: .utf8)
            let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)

            XCTAssertNil(
                timelineConstruction.firstMatch(in: source, range: sourceRange),
                "Do not place TimelineView in PlainsayApplication's MenuBarExtra hierarchy (\(path)); it leaks CPU and memory on macOS 26."
            )
        }
    }
}
