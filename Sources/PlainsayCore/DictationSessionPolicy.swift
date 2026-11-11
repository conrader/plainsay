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
/// spec-ranking/RANKING.md §3). Inputs plug into `make` with a fixed
/// precedence:
///
/// 1. **privacy** (this file) — always wins; it can only take capabilities
///    away, never grant one.
/// 2. **app profile** (`DictationProfile`) — may turn Polishing off, allow or
///    forbid email layout, set or clear translation, pick Copy only and add
///    vocabulary. Under `.privateLocal` its Polishing, translation, email and
///    output fields are forced off/plain/paste; its dictionary still applies,
///    because it is local.
/// 3. **notation/template mode** (devnotation/templates specs) — a mode and
///    route identity resolved inside whatever 1–2 leave allowed.
///
/// The policy is a ceiling, not an entitlement. `allowsCleanup == true` means
/// "the normal settings and paid-feature gates decide", and the coordinator
/// still evaluates those (`resolvedDictationStyle(for:)` checks the Cloud
/// entitlement live). No input here can unlock a paid feature.
public struct DictationSessionPolicy: Sendable, Equatable {
    public let privacy: DictationPrivacy
    /// Polishing of any kind, including a `.custom` endpoint on localhost:
    /// "local" cannot be proven from a URL. Translation and email layout only
    /// ever reach the text through the cleaner, so they go with it. False for
    /// a private session, a Polishing-Off profile, or Default Polishing off
    /// at recording start.
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

    // MARK: Profile inputs (appprofiles, precedence level 2)

    /// The app profile chosen when recording started; nil means Default.
    public let profileID: UUID?
    /// Shown in the HUD chip only. Never logged.
    public let profileName: String?
    /// Profile terms first, then the Default vocabulary (deduplicated by
    /// `normalizedTerms`), frozen for the speech hint, live preview and local
    /// corrections. It is local, so privacy keeps it.
    public let dictionary: TermDictionary
    /// Email layout *requested* (snapshot). The entitlement and the webmail
    /// window title are still checked live by the coordinator.
    public let emailLayoutEnabled: Bool
    /// Translation target *requested* (snapshot); entitlement checked live.
    public let translateTo: String?
    /// The profile set Translation to Off while Default would translate; the
    /// HUD chip says so, because the chord/menu change only the global value.
    public let translationSuppressedByProfile: Bool
    public let output: DictationOutput
    /// Remember-correction rules (SPEC.fixed.md §3.3), frozen like
    /// `dictionary`: a rule added, changed, disabled or deleted while
    /// recording or Polishing applies from the next dictation. Local, so
    /// privacy keeps them.
    public let replacementRules: ReplacementRuleSet

    private init(privacy: DictationPrivacy, defaults: DictationDefaults, profile: DictationProfile?) {
        let standard = privacy == .standard
        self.privacy = privacy
        stagesRecoveryAudio = standard
        writesHistory = standard
        writesDebugAudio = standard
        keepsLastDictation = standard
        logsBundleIdentifiers = standard
        honorsKeepOnClipboard = standard
        concealsPasteboard = !standard

        profileID = profile?.id
        profileName = profile?.name
        dictionary = TermDictionary(terms: (profile?.extraTerms ?? []) + defaults.dictionary.terms)
        replacementRules = defaults.replacementRules

        // Polishing: privacy, then the profile (Off only, Q3), then the
        // Default switch frozen here. Provider/key stay live in `makeCleaner`,
        // so a switch turned *off* mid-recording still applies (fail-closed).
        let cleanup = standard && profile?.polishing != .off && defaults.cleanupEnabled
        allowsCleanup = cleanup

        // Email and translation run inside the cleaner, so they go with it.
        let email: Bool
        switch profile?.emailLayout ?? .inherit {
        case .inherit: email = defaults.emailModeEnabled
        case .composers: email = true
        case .off: email = false
        }
        emailLayoutEnabled = cleanup && email

        let translation: String?
        switch profile?.translation ?? .inherit {
        case .inherit: translation = defaults.translationTargetLanguage
        case .off: translation = nil
        case .target(let code): translation = code
        }
        translateTo = cleanup ? translation : nil
        translationSuppressedByProfile = cleanup && profile?.translation == .off
            && defaults.translationTargetLanguage != nil

        // Private always pastes and restores the clipboard when it can.
        output = standard && profile?.output == .copyOnly ? .copyOnly : .paste
    }

    /// The behaviour every dictation had before this type existed.
    public static let standard = DictationSessionPolicy(privacy: .standard, defaults: .none, profile: nil)

    /// The one resolver. Pure: no I/O and no settings reads (the coordinator
    /// passes `defaults` read once at recording start), so it can be frozen
    /// and unit-tested. Precedence: privacy > profile > Default. Extension
    /// point: notation/template modes are added here as further defaulted
    /// parameters, applied inside whatever privacy and the profile allow.
    public static func make(
        privacy: DictationPrivacy = .standard,
        defaults: DictationDefaults = .none,
        profile: DictationProfile? = nil
    ) -> DictationSessionPolicy {
        DictationSessionPolicy(privacy: privacy, defaults: defaults, profile: profile)
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

/// The global settings a session starts from, read once by the coordinator
/// when recording starts so the resolver itself stays pure.
public struct DictationDefaults: Sendable, Equatable {
    public var dictionary: TermDictionary
    public var cleanupEnabled: Bool
    public var emailModeEnabled: Bool
    public var translationTargetLanguage: String?
    public var replacementRules: ReplacementRuleSet

    public init(
        dictionary: TermDictionary = TermDictionary(),
        cleanupEnabled: Bool = true,
        emailModeEnabled: Bool = false,
        translationTargetLanguage: String? = nil,
        replacementRules: ReplacementRuleSet = ReplacementRuleSet()
    ) {
        self.dictionary = dictionary
        self.cleanupEnabled = cleanupEnabled
        self.emailModeEnabled = emailModeEnabled
        self.translationTargetLanguage = translationTargetLanguage
        self.replacementRules = replacementRules
    }

    /// Outside a session: nothing requested.
    public static let none = DictationDefaults()
}

/// Where the text goes after a dictation.
public enum DictationOutput: Sendable, Equatable {
    case paste
    /// Clipboard only: never sends ⌘V, never reacquires the target.
    case copyOnly
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
