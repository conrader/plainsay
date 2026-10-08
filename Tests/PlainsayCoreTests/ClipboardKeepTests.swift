import Testing
@testable import PlainsayCore

/// A ⌘V sent without a confirmed text field may land nowhere. Putting the old
/// clipboard back afterwards then leaves the dictation only in History.
@Suite("Clipboard after an unconfirmed paste")
struct ClipboardKeepTests {
    @Test("Only a focused element confirms a text field; a focused window alone does not")
    func certainty() {
        func certainty(
            _ element: PasteboardTextInserter.AccessibilityValueState,
            _ window: PasteboardTextInserter.AccessibilityValueState,
            fallback: Bool
        ) -> PasteTargetCertainty {
            PasteboardTextInserter.pasteTargetCertainty(
                focusedElement: element,
                focusedWindow: window,
                allowsFocusedWindowFallback: fallback
            )
        }
        #expect(certainty(.present, .absent, fallback: false) == .confirmed)
        // An Electron app with nothing focused that Accessibility can see.
        #expect(certainty(.absent, .present, fallback: true) == .unconfirmed)
        // An unreadable element probe.
        #expect(certainty(.unknown, .present, fallback: false) == .unconfirmed)
        #expect(certainty(.unknown, .absent, fallback: true) == .none)
        #expect(certainty(.absent, .present, fallback: false) == .none)
    }

    @Test("Unconfirmed paste: the dictation stays on the clipboard")
    func unconfirmedKeepsDictation() {
        #expect(!PasteboardTextInserter.restoresPreviousClipboard(certainty: .unconfirmed, keepOnClipboard: false))
    }

    @Test("Confirmed paste: the previous clipboard is restored as before")
    func confirmedRestores() {
        #expect(PasteboardTextInserter.restoresPreviousClipboard(certainty: .confirmed, keepOnClipboard: false))
    }

    @Test("With restoring turned off in settings, nothing changes either way")
    func settingStillWins() {
        #expect(!PasteboardTextInserter.restoresPreviousClipboard(certainty: .confirmed, keepOnClipboard: true))
        #expect(!PasteboardTextInserter.restoresPreviousClipboard(certainty: .unconfirmed, keepOnClipboard: true))
    }

    @Test("The decision log says whether the dictation was kept on the clipboard")
    func logLine() {
        let report = PasteTargetReport(
            decision: .paste,
            reason: "windowUnverified",
            reactivationAttempted: false,
            frontmostBundleIdentifier: "com.example.electron"
        )
        func line(_ outcome: TextInsertionOutcome, setting: Bool) -> String {
            PasteDecisionLog.message(
                outcome: outcome,
                report: report,
                targetBundleIdentifier: "com.example.electron",
                frontmostBundleIdentifier: nil,
                keepOnClipboardSetting: setting
            )
        }
        let prefix = "paste decision=paste reason=windowUnverified target=com.example.electron"
            + " reactivationAttempted=false frontmost=com.example.electron"
        #expect(line(.insertedUnconfirmed, setting: false) == prefix + " clipboardKept=true")
        #expect(line(.inserted, setting: false) == prefix + " clipboardKept=false")
        #expect(line(.inserted, setting: true) == prefix + " clipboardKept=true")
    }
}
