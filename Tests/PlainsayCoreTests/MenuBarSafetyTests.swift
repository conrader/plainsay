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
        let applicationSource = repositoryRoot
            .appendingPathComponent("Sources/PlainsayApp/PlainsayApplication.swift")
        let source = try String(contentsOf: applicationSource, encoding: .utf8)
        let timelineConstruction = try NSRegularExpression(pattern: #"\bTimelineView\s*\("#)
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)

        XCTAssertNil(
            timelineConstruction.firstMatch(in: source, range: sourceRange),
            "Do not place TimelineView in PlainsayApplication's MenuBarExtra hierarchy; it leaks CPU and memory on macOS 26."
        )
    }
}
