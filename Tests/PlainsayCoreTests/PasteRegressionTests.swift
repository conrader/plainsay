import AppKit
import Foundation
import Testing
@testable import PlainsayCore

// The false "not pasted" notices of issue #55's follow-up: dictations held on
// the clipboard while the user never left the field they dictated into. Each
// test here failed before the fix.
@Suite("Paste false-refusal regression")
struct PasteRegressionTests {
    /// A minimal `.app` on disk, with or without Electron's framework inside.
    private func makeBundle(electron: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsay-paste-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Grok Bot.app", isDirectory: true)
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        if electron {
            try FileManager.default.createDirectory(
                at: frameworks.appendingPathComponent("Electron Framework.framework", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return app
    }

    @Test("An Electron app that hides its focused editor still gets the paste")
    func electronAppUsesFocusedWindow() throws {
        // What happened: Grok Bot (`com.anysphere.sand`, Electron) was in
        // front the whole time, Accessibility said "no focused element"
        // because Chromium keeps its tree off until asked, and every
        // dictation went to the clipboard. Codex had the same problem and an
        // exception by bundle id; this is the same app shape.
        let app = try makeBundle(electron: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let allowed = PasteboardTextInserter.allowsFocusedWindowFallback(
            bundleIdentifier: "com.anysphere.sand",
            bundleURL: app
        )
        #expect(allowed)
        #expect(PasteboardTextInserter.shouldAttemptPaste(
            focusedElement: .absent,
            focusedWindow: .present,
            allowsFocusedWindowFallback: allowed
        ))
    }

    @Test("A native app with nothing focused still keeps the dictation on the clipboard")
    func nativeAppWithoutFocusKeepsClipboard() throws {
        let app = try makeBundle(electron: false)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        #expect(!PasteboardTextInserter.allowsFocusedWindowFallback(
            bundleIdentifier: "com.example.native",
            bundleURL: app
        ))
        #expect(PasteboardTextInserter.allowsFocusedWindowFallback(
            bundleIdentifier: "com.openai.codex",
            bundleURL: nil
        ))
    }

    @Test("Plainsay in front at paste time is not a switch")
    func plainsayInFrontIsNotASwitch() {
        // Its HUD, menu or a window of its own can be in front for a moment;
        // none of that is the user going somewhere else.
        let observation = PasteTargetObservation(isTerminated: false, front: .plainsay, focusedWindowStillMatches: nil)
        #expect(FrontmostPasteTarget.decide(observation) == .paste)
    }

    @Test("No frontmost app at all is doubt, and doubt pastes")
    func unknownFrontPastes() {
        let observation = PasteTargetObservation(isTerminated: false, front: .unknown, focusedWindowStillMatches: nil)
        #expect(FrontmostPasteTarget.decide(observation) == .paste)
    }

    @Test("Plainsay is never captured as the paste target")
    @MainActor
    func plainsayIsNeverTheTarget() {
        // A target that is Plainsay would be "re-activated" at paste time,
        // pulling Plainsay over the app the user is actually in.
        #expect(FrontmostPasteTarget.target(for: NSRunningApplication.current) == nil)
    }
}
