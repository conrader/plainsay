import AppKit
import ApplicationServices

/// Why a dictation could not go where it was aimed.
///
/// String-backed on purpose: these names go into the unified log, which is
/// where a report of "it did not paste" gets diagnosed from, and the three
/// causes need different fixes. Renaming one makes older logs unsearchable.
public enum PasteTargetLoss: String, Equatable, Sendable {
    /// The app quit while the dictation was being transcribed or polished.
    case appTerminated
    /// It is not in front, and asking did not bring it back. macOS can
    /// decline an activation it has nominally accepted, so a request is not a
    /// result.
    case notFrontmost
    /// The right app is in front, but focus inside it is on a different
    /// window than the one dictated into.
    case windowChanged
}

/// Whether the dictation may be pasted.
public enum PasteTargetDecision: Equatable, Sendable {
    /// The target has the focus — it either never lost it, or it was given it
    /// back. Paste exactly as before any of this existed.
    case paste
    /// Send no ⌘V. A paste now would land somewhere nobody dictated into,
    /// which may be a password field, a shell prompt, or somebody else's chat
    /// window; the dictation waits on the clipboard for a ⌘V the user aims
    /// themselves.
    case keepOnClipboard(PasteTargetLoss)
}

/// Which app is in front when the decision is made, relative to the target.
public enum PasteTargetFront: Equatable, Sendable {
    /// The app the dictation was aimed at.
    case target
    /// Plainsay itself: its HUD, menu-bar menu or one of its windows.
    case plainsay
    /// Some other app.
    case otherApp
    /// `NSWorkspace` named no frontmost app at all.
    case unknown
}

/// What is known about a remembered target at the moment of deciding.
///
/// A plain value with no AppKit in it, so the policy below is a pure function
/// of an observation rather than of the machine the code is running on.
public struct PasteTargetObservation: Equatable, Sendable {
    public let isTerminated: Bool
    public let front: PasteTargetFront
    public var isFrontmost: Bool { front == .target }
    /// Whether focus is on the window that was captured.
    ///
    /// Nil means Accessibility could not say — no grant, or an app that
    /// publishes no focused window. That is *no evidence*, never "wrong
    /// window": the same reading `FocusedWindow` already takes of the same
    /// probe.
    public let focusedWindowStillMatches: Bool?

    public init(isTerminated: Bool, front: PasteTargetFront, focusedWindowStillMatches: Bool?) {
        self.isTerminated = isTerminated
        self.front = front
        self.focusedWindowStillMatches = focusedWindowStillMatches
    }

    /// "Not frontmost" here means another app is.
    public init(isTerminated: Bool, isFrontmost: Bool, focusedWindowStillMatches: Bool?) {
        self.init(
            isTerminated: isTerminated,
            front: front(),
            focusedWindowStillMatches: focusedWindowStillMatches
        )
    }
}

/// Where a dictation in flight is meant to land.
@MainActor
public protocol DictationPasteTargeting: Sendable {
    var bundleIdentifier: String? { get }
    /// Get the focus back if it has moved, then say whether pasting is safe.
    func reacquire() async -> PasteTargetDecision
    /// How the last `reacquire` reached its decision, for the log.
    var lastReport: PasteTargetReport? { get }
}

extension DictationPasteTargeting {
    public var lastReport: PasteTargetReport? { nil }
}

/// One decision and what it was based on. Never holds any dictated text.
public struct PasteTargetReport: Equatable, Sendable {
    public let decision: PasteTargetDecision
    /// Stable name for why: a `PasteTargetLoss` raw value, or why a paste was
    /// allowed (`targetInFront`, `windowUnverified`, `frontmostIsPlainsay`,
    /// `frontmostUnknown`).
    public let reason: String
    public let reactivationAttempted: Bool
    public let frontmostBundleIdentifier: String?
}

/// The app — and where Accessibility will say, the exact window — that was in
/// front when a dictation started.
///
/// Remembered because a dictation is not instantaneous. Transcription and
/// Polishing take seconds, and a slow or failing cleanup provider can make
/// that many seconds; whatever is frontmost when the answer finally arrives
/// is not necessarily what the user was dictating into.
@MainActor
public final class FrontmostPasteTarget: DictationPasteTargeting {
    private let application: NSRunningApplication
    /// The focused window *element*, not its title.
    ///
    /// Identity is the point. A window's title changes on the first keystroke
    /// after a dictation starts — an editor marking a document dirty, a
    /// browser tab finishing its load — so comparing titles would report
    /// "wrong window" for ordinary typing. `DictationInsertionAnchor` compares
    /// window elements with `CFEqual` for exactly this reason.
    private let window: AXUIElement?
    /// How long an accepted activation gets to take effect.
    ///
    /// 200ms is what `DictationInsertionAnchor.replace` already waits after
    /// its own `activate` before trusting focus, and that wait has shipped.
    private let activationDelay: Duration

    public var bundleIdentifier: String? { application.bundleIdentifier }
    public private(set) var lastReport: PasteTargetReport?

    init(application: NSRunningApplication, activationDelay: Duration = .milliseconds(200)) {
        self.application = application
        self.window = Self.focusedWindow(of: application)
        self.activationDelay = activationDelay
    }

    /// Whatever is frontmost right now, with its focused window when
    /// Accessibility will say.
    public static func capture() -> FrontmostPasteTarget? {
        target(for: NSWorkspace.shared.frontmostApplication)
    }

    /// Nil for Plainsay itself. A Plainsay target would be "re-activated" at
    /// paste time, pulling Plainsay over whatever the user is actually in.
    /// With no target the paste goes to whatever is frontmost, which keeps
    /// dictating into Plainsay's own text field working as it always has.
    static func target(for application: NSRunningApplication?) -> FrontmostPasteTarget? {
        guard let application, !isPlainsay(application) else { return nil }
        return FrontmostPasteTarget(application: application)
    }

    private static func isPlainsay(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    public func reacquire() async -> PasteTargetDecision {
        // Only activate when something else has the front. An app that never
        // lost it gets no activation request at all. A Plainsay window in
        // front is asked to give the target back too, so that the paste does
        // not land in one of Plainsay's own fields — but if it stays, that is
        // still not the user switching apps.
        let currentFront = front()
        let reactivate = !application.isTerminated && (currentFront == .otherApp || currentFront == .plainsay)
        if reactivate {
            // The Bool is discarded on purpose: `activate` can report success
            // and not take, and can report failure on an app that is already
            // coming forward. The observation below is the only answer worth
            // believing.
            _ = application.activate(options: [])
            try? await Task.sleep(for: activationDelay)
        }
        let (decision, reason) = Self.judge(observe())
        lastReport = PasteTargetReport(
            decision: decision,
            reason: reason,
            reactivationAttempted: reactivate,
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        return decision
    }

    /// The verdict, as a pure function of what was observed.
    ///
    /// Separated from every AppKit call that feeds it because none of the
    /// interesting cases can be staged with real applications — an app that
    /// quit, focus that will not come back, a second window of the same app —
    /// least of all on a CI runner with no window server. Order matters and
    /// is asserted: the cause named in the log has to be the one that
    /// actually happened, and a terminated app would otherwise read as merely
    /// not frontmost.
    ///
    /// If in doubt, paste: only positive evidence that the user is somewhere
    /// else withholds it. Plainsay's own HUD, menu or window in front is not
    /// the user going anywhere, and neither is `NSWorkspace` naming nobody.
    nonisolated static func decide(_ observation: PasteTargetObservation) -> PasteTargetDecision {
        judge(observation).decision
    }

    nonisolated static func judge(_ observation: PasteTargetObservation) -> (decision: PasteTargetDecision, reason: String) {
        if observation.isTerminated { return lost(.appTerminated) }
        switch observation.front {
        case .otherApp: return lost(.notFrontmost)
        case .plainsay: return (.paste, "frontmostIsPlainsay")
        case .unknown: return (.paste, "frontmostUnknown")
        case .target: break
        }
        // Only a positive "different window" withholds the paste. Reading an
        // unanswerable probe as the wrong window would send every dictation in
        // an app that publishes no focused window to the clipboard — worse
        // than the bug being guarded against, because text would stop
        // arriving where it currently arrives fine.
        guard let sameWindow = observation.focusedWindowStillMatches else { return (.paste, "windowUnverified") }
        return sameWindow ? (.paste, "targetInFront") : lost(.windowChanged)
    }

    private nonisolated static func lost(_ loss: PasteTargetLoss) -> (decision: PasteTargetDecision, reason: String) {
        (.keepOnClipboard(loss), loss.rawValue)
    }

    private func observe() -> PasteTargetObservation {
        PasteTargetObservation(
            isTerminated: application.isTerminated,
            front: front(),
            focusedWindowStillMatches: focusedWindowStillMatches()
        )
    }

    /// Compared by process identifier rather than by `NSRunningApplication`
    /// identity: `frontmostApplication` is free to hand back a different
    /// instance for the same running app, and the pid is what
    /// `DictationInsertionAnchor.focusMatches` already compares.
    private func front() -> PasteTargetFront {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return .unknown }
        if frontmost.processIdentifier == application.processIdentifier { return .target }
        return Self.isPlainsay(frontmost) ? .plainsay : .otherApp
    }

    /// False only on positive evidence: the captured window still answers
    /// Accessibility, so it still exists, and focus is on another one.
    /// A window element that no longer answers may simply have been
    /// re-created by its app, which is doubt, not a different window.
    private func focusedWindowStillMatches() -> Bool? {
        guard AXIsProcessTrusted(), let window, let focused = Self.focusedWindow(of: application) else { return nil }
        if CFEqual(window, focused) { return true }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return false
    }

    private static func focusedWindow(of application: NSRunningApplication) -> AXUIElement? {
        // Asking an app that has not granted Accessibility returns an error
        // rather than prompting, which is what we want: a dictation is
        // starting, and a permission dialog would steal the very focus we are
        // trying to remember.
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return (window as! AXUIElement)
    }
}
