import Testing
@testable import PlainsayCore

@Suite("Paste decision log line")
struct PasteDecisionLogTests {
    @Test("A paste names its reason, the target, the re-activation and the frontmost app")
    func pasteLine() {
        let report = PasteTargetReport(
            decision: .paste,
            reason: "targetInFront",
            reactivationAttempted: false,
            frontmostBundleIdentifier: "com.anysphere.sand"
        )
        #expect(PasteDecisionLog.message(
            outcome: .inserted,
            report: report,
            targetBundleIdentifier: "com.anysphere.sand",
            frontmostBundleIdentifier: "com.example.later",
            keepOnClipboardSetting: false
        ) == "paste decision=paste reason=targetInFront target=com.anysphere.sand reactivationAttempted=false frontmost=com.anysphere.sand clipboardKept=false")
    }

    @Test("A clipboard fallback names which check refused")
    func clipboardLines() {
        let report = PasteTargetReport(
            decision: .keepOnClipboard(.notFrontmost),
            reason: "notFrontmost",
            reactivationAttempted: true,
            frontmostBundleIdentifier: "com.example.chat"
        )
        #expect(PasteDecisionLog.message(
            outcome: .targetUnavailable(.notFrontmost),
            report: report,
            targetBundleIdentifier: "com.example.editor",
            frontmostBundleIdentifier: nil,
            keepOnClipboardSetting: false
        ) == "paste decision=keepOnClipboard reason=notFrontmost target=com.example.editor reactivationAttempted=true frontmost=com.example.chat clipboardKept=true")
        #expect(PasteDecisionLog.message(
            outcome: .noFocusedElement,
            report: nil,
            targetBundleIdentifier: nil,
            frontmostBundleIdentifier: nil,
            keepOnClipboardSetting: false
        ) == "paste decision=keepOnClipboard reason=nothingFocused target=none reactivationAttempted=false frontmost=unknown clipboardKept=true")
    }

    @Test("Every policy outcome has a stable reason name")
    func policyReasons() {
        func reason(_ front: PasteTargetFront, _ window: Bool?, terminated: Bool = false) -> String {
            FrontmostPasteTarget.judge(PasteTargetObservation(
                isTerminated: terminated,
                front: front,
                focusedWindowStillMatches: window
            )).reason
        }
        #expect(reason(.target, true) == "targetInFront")
        #expect(reason(.target, nil) == "windowUnverified")
        #expect(reason(.target, false) == "windowChanged")
        #expect(reason(.plainsay, nil) == "frontmostIsPlainsay")
        #expect(reason(.unknown, nil) == "frontmostUnknown")
        #expect(reason(.otherApp, true) == "notFrontmost")
        #expect(reason(.otherApp, nil, terminated: true) == "appTerminated")
    }
}
