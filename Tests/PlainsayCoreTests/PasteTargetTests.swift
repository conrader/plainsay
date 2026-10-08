import Foundation
import Testing
@testable import PlainsayCore

// Where a dictation is allowed to land. The policy is a pure function of an
// observation precisely so this suite needs no second application to steal
// focus from, no Accessibility grant, and no window server — the parts that
// would otherwise make it a manual test nobody runs.
@Suite("Paste target policy")
struct PasteTargetTests {
    private func observation(
        terminated: Bool = false,
        frontmost: Bool = true,
        window: Bool? = true
    ) -> PasteTargetObservation {
        PasteTargetObservation(
            isTerminated: terminated,
            isFrontmost: frontmost,
            focusedWindowStillMatches: window
        )
    }

    @Test("Nothing moved, so the dictation goes where it was aimed")
    func intactTargetPastes() {
        #expect(FrontmostPasteTarget.decide(observation()) == .paste)
    }

    @Test("An app that quit mid-dictation gets no paste")
    func terminatedAppKeepsOnClipboard() {
        // Checked before anything else: a terminated app cannot be frontmost
        // and has no focused window, so every other probe would read as a
        // different failure and name the wrong cause in the log.
        #expect(
            FrontmostPasteTarget.decide(observation(terminated: true, frontmost: false, window: nil))
                == .keepOnClipboard(.appTerminated)
        )
    }

    @Test("Focus that would not come back gets no paste")
    func focusNotRestoredKeepsOnClipboard() {
        #expect(
            FrontmostPasteTarget.decide(observation(frontmost: false))
                == .keepOnClipboard(.notFrontmost)
        )
    }

    @Test("The right app but a different window gets no paste")
    func differentWindowKeepsOnClipboard() {
        // The subtle half of the bug. Switching between two windows of the
        // same app leaves the app frontmost, so an app-level check alone would
        // happily paste a dictation into the wrong document of the right
        // program.
        #expect(
            FrontmostPasteTarget.decide(observation(window: false))
                == .keepOnClipboard(.windowChanged)
        )
    }

    @Test("A window that cannot be read is no evidence, and does not block the paste")
    func unreadableWindowStillPastes() {
        // nil is "could not tell" — no Accessibility grant, or an app that
        // publishes no focused window. Treating that as the wrong window would
        // send every dictation in such an app to the clipboard, which is worse
        // than the bug being guarded against: the text would stop arriving in
        // apps where it currently arrives fine. Same reading `FocusedWindow`
        // already takes for the same probe.
        #expect(FrontmostPasteTarget.decide(observation(window: nil)) == .paste)
    }

    @Test("A gone app is reported as gone even when the window probe also fails")
    func terminationOutranksAnUnreadableWindow() {
        #expect(
            FrontmostPasteTarget.decide(observation(terminated: true, window: nil))
                == .keepOnClipboard(.appTerminated)
        )
    }

    @Test("Losing focus is reported as that, not as a window change")
    func focusLossOutranksWindowChange() {
        // Both are true when the user switches to another app: it is not
        // frontmost, and its focused window reads as something else. The
        // reason in the log should be the one that actually describes what
        // happened.
        #expect(
            FrontmostPasteTarget.decide(observation(frontmost: false, window: false))
                == .keepOnClipboard(.notFrontmost)
        )
    }

    @Test("Every loss has a stable name for the log")
    func lossReasonsAreNamed() {
        // These strings go into the unified log, which is where a report of
        // "it did not paste" gets diagnosed from. Renaming one silently would
        // make older logs unsearchable.
        #expect(PasteTargetLoss.appTerminated.rawValue == "appTerminated")
        #expect(PasteTargetLoss.notFrontmost.rawValue == "notFrontmost")
        #expect(PasteTargetLoss.windowChanged.rawValue == "windowChanged")
    }
}
