import Foundation

/// Whether a dictation may leave anything behind in Plainsay-controlled
/// storage, or reach anything but the on-device engine that is already loaded.
public enum DictationPrivacy: Sendable, Equatable {
    case standard
    /// "Private next dictation": the prepared on-device engine only, no
    /// Polishing/translation/email layout, and nothing written to History,
    /// crash-recovery audio, debug audio or `lastDictation`.
    case privateLocal
}

/// What one dictation is allowed to do, decided once when recording starts and
/// frozen until that work unit ends.
///
/// This is the single resolver the session-level features share (R1 in
/// spec-ranking/RANKING.md §3). Only the privacy input exists today. Later
/// inputs plug into `make` with a fixed precedence:
///
/// 1. **privacy** (this file) — always wins; it can only take capabilities
///    away, never grant one.
/// 2. **app profile** (appprofiles spec) — will add a `profile:` input that may
///    turn Polishing/translation/email/output off or pick a dictionary. Under
///    `.privateLocal` its Polishing, translation, email and output fields are
///    forced off/plain; its dictionary still applies, because it is local.
/// 3. **notation/template mode** (devnotation/templates specs) — a mode and
///    route identity resolved inside whatever 1–2 leave allowed.
///
/// The policy is a ceiling, not an entitlement. `allowsCleanup == true` means
/// "the normal settings and paid-feature gates decide", and the coordinator
/// still evaluates those (`resolvedDictationStyle()` checks the Cloud
/// entitlement live). No input here can unlock a paid feature.
public struct DictationSessionPolicy: Sendable, Equatable {
    public let privacy: DictationPrivacy
    /// Polishing of any kind, including a `.custom` endpoint on localhost:
    /// "local" cannot be proven from a URL. Translation and email layout only
    /// ever reach the text through the cleaner, so they go with it.
    public let allowsCleanup: Bool
    /// Crash-recovery `.f32` staging in `PendingAudioStore`.
    public let stagesRecoveryAudio: Bool
    /// Every `TranscriptHistory` write for this session, including outcome
    /// rewrites and acknowledgements.
    public let writesHistory: Bool
    /// The hidden `PlainsayDebugSaveAudio` diagnostic WAVs.
    public let writesDebugAudio: Bool
    /// `lastTranscript` / `lastDictation`, which feed "Correct last dictation"
    /// and therefore a hosted editor.
    public let keepsLastDictation: Bool
    /// App bundle identifiers in the unified-log paste decision line.
    public let logsBundleIdentifiers: Bool
    /// Whether the user's "keep dictation on clipboard" setting is honoured.
    /// Private pastes always restore the previous clipboard when they can.
    public let honorsKeepOnClipboard: Bool
    /// Mark Plainsay's pasteboard writes concealed + transient
    /// (nspasteboard.org). Whether a clipboard manager honours that is not
    /// something Plainsay controls.
    public let concealsPasteboard: Bool

    private init(privacy: DictationPrivacy) {
        let standard = privacy == .standard
        self.privacy = privacy
        allowsCleanup = standard
        stagesRecoveryAudio = standard
        writesHistory = standard
        writesDebugAudio = standard
        keepsLastDictation = standard
        logsBundleIdentifiers = standard
        honorsKeepOnClipboard = standard
        concealsPasteboard = !standard
    }

    /// The behaviour every dictation had before this type existed.
    public static let standard = DictationSessionPolicy(privacy: .standard)

    /// The one resolver. Pure: no I/O, no settings reads, so it can be frozen
    /// and unit-tested. Extension point: future `profile:` / mode inputs are
    /// added here as defaulted parameters, applied *after* privacy so privacy
    /// keeps the last word on everything it turns off.
    public static func make(privacy: DictationPrivacy = .standard) -> DictationSessionPolicy {
        DictationSessionPolicy(privacy: privacy)
    }

    /// Whether a private session may start right now. Pure; returns nil when
    /// it may.
    ///
    /// Checks the engine Plainsay actually *prepared*, not just the setting:
    /// Cloud reports `.ready` immediately, so `modelState` alone would let a
    /// Cloud engine through. The configured source is checked too, so a
    /// Speech change whose reload is still queued is refused as well.
    public static func privateRefusal(
        preparedSource: TranscriptionSource?,
        configuredSource: TranscriptionSource,
        modelState: SpeechModelLoadState
    ) -> PrivateDictationRefusal? {
        guard preparedSource == .onDevice, configuredSource == .onDevice else { return .notOnDevice }
        guard modelState == .ready else { return .modelNotReady }
        return nil
    }
}

/// Why "Private next dictation" cannot run. Never a reason to fall back to
/// Cloud or Remote: a refused private dictation records nothing.
public enum PrivateDictationRefusal: Sendable, Equatable {
    case notOnDevice
    case modelNotReady

    /// Short reason for the disabled menu item.
    public var menuReason: String {
        switch self {
        case .notOnDevice:
            Localization.coreString(
                "menu.private.needsOnDevice", fallback: "Needs on-device speech (Settings › Speech)"
            )
        case .modelNotReady:
            Localization.coreString(
                "menu.private.modelNotReady", fallback: "Available when the on-device model is ready"
            )
        }
    }

    /// Shown in the HUD when an armed dictation is refused at hotkey time.
    public static var refusedMessage: String {
        Localization.coreString(
            "coordinator.private.refused",
            fallback: "Private dictation needs the on-device model. Nothing was recorded."
        )
    }
}
