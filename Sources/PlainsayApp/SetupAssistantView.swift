import SwiftUI
import PlainsayCore

struct SetupAssistantView: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    let permissionStatus: PermissionStatus
    let onSpeechConfirmed: @MainActor (Bool) -> Void
    let onFinish: @MainActor () -> Void

    @State private var step: Step
    // Lives here, not in SpeechSetupStep: `continueRequirement` below reads
    // settings.apiKey(for:), a Keychain read SwiftUI's observation can't see.
    // A child's local @State can't invalidate this parent's body, so the
    // revision has to be owned where the thing that depends on it lives.
    @State private var asrKeyRevision = 0
    @State private var speechSource: TranscriptionSource
    @State private var speechModel: OnDeviceModel
    // Set the moment someone taps a model card directly, so the
    // language-based recommendation (applied when entering .configure)
    // never overwrites a choice they already made themselves.
    @State private var speechModelWasManuallyChosen = false

    init(
        settings: PlainsaySettings,
        coordinator: DictationCoordinator,
        permissionStatus: PermissionStatus,
        onSpeechConfirmed: @escaping @MainActor (Bool) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.settings = settings
        self.coordinator = coordinator
        self.permissionStatus = permissionStatus
        self.onSpeechConfirmed = onSpeechConfirmed
        self.onFinish = onFinish

        // A first-run choice stays a draft until Continue. A fresh settings
        // store defaults to Local, while reopening the assistant reflects
        // whatever source the user is already using.
        // Resumes where an interrupted run left off. Cleared on Done, so
        // deliberately reopening the assistant later still starts at the top.
        _step = State(initialValue: Step(rawValue: settings.onboardingStep) ?? .speech)
        _speechSource = State(initialValue: settings.transcriptionSource)
        _speechModel = State(
            initialValue: settings.needsOnboarding
                // A fresh setup has no real choice to respect yet — recommend
                // based on whatever languages are already on file (usually
                // none, which the recommendation treats the same as Parakeet).
                // A returning user's own settings.model is left untouched.
                ? OnDeviceModel.recommended(for: settings.spokenLanguages)
                : settings.model
        )
    }

    private enum Step: Int, CaseIterable, Identifiable {
        case speech
        case language
        case configure
        case voice
        case shortcut
        case permissions
        case ready

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .speech: Localization.appString("wizard.step.speech", fallback: "Speech")
            case .configure: Localization.appString("wizard.step.configure", fallback: "Configure")
            case .language: Localization.appString("wizard.step.refine", fallback: "Refine")
            case .voice: Localization.appString("wizard.step.voice", fallback: "Voice")
            case .shortcut: Localization.appString("wizard.step.shortcut", fallback: "Shortcut")
            case .permissions: Localization.appString("wizard.step.permissions", fallback: "Permissions")
            case .ready: Localization.appString("wizard.step.ready", fallback: "Ready")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                languageCorner
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            stepIndicator
                .padding(.horizontal, 36)
                .padding(.vertical, 18)

            Divider()

            ScrollView {
                Group {
                    switch step {
                    case .speech:
                        SpeechSetupStep(source: $speechSource)
                    case .language:
                        LanguageSetupStep(
                            speechSource: speechSource,
                            settings: settings,
                            coordinator: coordinator
                        )
                    case .configure:
                        ConfigureSpeechSetupStep(
                            source: $speechSource,
                            model: $speechModel,
                            modelWasManuallyChosen: $speechModelWasManuallyChosen,
                            settings: settings,
                            coordinator: coordinator,
                            asrKeyRevision: $asrKeyRevision
                        )
                    case .voice:
                        VoiceSetupStep(settings: settings)
                    case .shortcut:
                        ShortcutSetupStep(settings: settings)
                    case .permissions:
                        PermissionsSetupStep(permissionStatus: permissionStatus)
                    case .ready:
                        ReadySetupStep(
                            settings: settings,
                            coordinator: coordinator,
                            permissionStatus: permissionStatus
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 42)
                .padding(.vertical, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            navigation
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 700, minHeight: 660)
        .onChange(of: settings.binding) { coordinator.settingsChanged() }
        .onChange(of: settings.hotkeyMode) { coordinator.settingsChanged() }
        .onChange(of: step) { _, newStep in
            // Written before the guard below returns: this has to record every
            // step, not just the one that triggers the model recommendation.
            settings.onboardingStep = newStep.rawValue
            // Refine (spoken languages) now comes before Configure, so by the
            // time someone reaches it, the recommendation reflects languages
            // they just chose — but only for a still-fresh setup, and only if
            // they haven't already tapped a model card themselves.
            guard newStep == .configure, settings.needsOnboarding, speechSource == .onDevice,
                  !speechModelWasManuallyChosen
            else { return }
            speechModel = OnDeviceModel.recommended(for: settings.spokenLanguages)
        }
        .environment(\.locale, Locale(identifier: Localization.resolvedCode(override: settings.interfaceLanguage)))
    }

    /// A small, always-present control rather than its own wizard step: a
    /// single picker with one meaningful choice made a page that was mostly
    /// empty space, and the language someone reads the rest of the wizard in
    /// is a decision that belongs before step 1, not as step 1.
    private var languageCorner: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("", selection: $settings.interfaceLanguage) {
                ForEach(AppLanguage.all) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Localization.appString("Interface language", fallback: "Interface language"))
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases) { item in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.16))
                            .frame(width: 24, height: 24)

                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        } else {
                            Text("\(item.rawValue + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(item.rawValue == step.rawValue ? Color.white : Color.secondary)
                        }
                    }

                    Text(item.title)
                        .font(.callout.weight(item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    Localization.appFormat(
                        "wizard.step.a11y", fallback: "Step %d, %@", item.rawValue + 1, item.title
                    )
                )

                if item != Step.allCases.last {
                    Capsule()
                        .fill(item.rawValue < step.rawValue ? Color.accentColor : Color.secondary.opacity(0.16))
                        .frame(maxWidth: .infinity, maxHeight: 2)
                }
            }
        }
    }

    private var navigation: some View {
        HStack {
            Button("Back") {
                guard let previous = Step(rawValue: step.rawValue - 1) else { return }
                step = previous
            }
            .disabled(step == .speech)

            Spacer()

            if step == .ready {
                Button("Done") {
                    settings.onboardingStep = 0
                    onFinish()
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    if let continueRequirement {
                        Text(continueRequirement)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(continueTitle) {
                        let leavingConfigure = step == .configure
                        guard let next = Step(rawValue: step.rawValue + 1) else { return }
                        step = next

                        // Reaching the final page means the configuration has
                        // been made. Closing the window's red control from
                        // there must not resurrect the assistant next launch.
                        if next == .ready {
                            settings.onboardingVersion = PlainsaySettings.currentOnboardingVersion
                        }

                        if leavingConfigure {
                            // Only this explicit transition commits the draft.
                            // Cloud also commits the Polishing included in its
                            // subscription; Local and BYOK leave that separate
                            // choice exactly as configured on the prior step.
                            let changed = settings.applySetupSpeechSelection(
                                source: speechSource,
                                model: speechModel
                            )
                            onSpeechConfirmed(changed)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(continueRequirement != nil)
                }
            }
        }
    }

    private var continueRequirement: String? {
        guard step == .configure else { return nil }
        switch speechSource {
        case .cloud:
            return coordinator.cloud.account?.isActive == true
                ? nil
                : Localization.appString(
                    "wizard.continueRequirement.cloud", fallback: "Sign in and activate Cloud above to continue"
                )
        case .remote:
            return settings.apiKey(for: settings.asrProvider).isEmpty
                ? Localization.appString(
                    "wizard.continueRequirement.byok", fallback: "Add your provider key above to continue"
                )
                : nil
        case .onDevice:
            return nil
        }
    }

    private var continueTitle: String {
        guard step == .speech || step == .configure else {
            return Localization.appString("wizard.continueTitle.default", fallback: "Continue")
        }
        return switch speechSource {
        case .cloud: Localization.appString("wizard.continueTitle.cloud", fallback: "Continue with Cloud")
        case .onDevice: Localization.appString("wizard.continueTitle.local", fallback: "Continue with Local")
        case .remote: Localization.appString("wizard.continueTitle.byok", fallback: "Continue with my API")
        }
    }
}

private struct SpeechSetupStep: View {
    @Binding var source: TranscriptionSource

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupHeading(
                icon: "waveform.badge.mic",
                colors: [.indigo, .blue],
                title: Localization.appString("wizard.speech.title", fallback: "Choose your Plainsay experience"),
                detail: Localization.appString(
                    "wizard.speech.detail",
                    fallback: "Keep speech recognition and recorded audio on this Mac for free, or use Plainsay Cloud without downloading a transcription model. The next step configures whichever you pick."
                )
            )

            HStack(alignment: .top, spacing: 14) {
                PlanCard(
                    isSelected: source == .onDevice,
                    icon: "lock.shield.fill",
                    colors: [.green, .mint],
                    eyebrow: Localization.appString("wizard.plan.local.eyebrow", fallback: "LOCAL SPEECH"),
                    title: Localization.appString("wizard.plan.local.title", fallback: "On this Mac"),
                    price: Localization.appString("wizard.plan.local.price", fallback: "Free"),
                    features: [
                        Localization.appString(
                            "wizard.plan.local.feature1", fallback: "Recorded audio never leaves this Mac"
                        ),
                        Localization.appString(
                            "wizard.plan.local.feature2", fallback: "Works without internet after setup"
                        ),
                    ],
                    caveats: [
                        Localization.appString(
                            "wizard.plan.local.caveat1", fallback: "Needs storage for the model, downloaded once"
                        ),
                        Localization.appString(
                            "wizard.plan.local.caveat2",
                            fallback: "Keeps using memory the whole time Plainsay is running, not just while dictating"
                        ),
                        Localization.appString(
                            "wizard.plan.local.caveat3", fallback: "May slightly slow this Mac down"
                        ),
                    ],
                    action: { source = .onDevice }
                )

                PlanCard(
                    isSelected: source == .cloud,
                    icon: "cloud.fill",
                    colors: [.indigo, .blue],
                    eyebrow: Localization.appString(
                        "wizard.plan.cloud.eyebrow", fallback: "NO TRANSCRIPTION-MODEL DOWNLOAD"
                    ),
                    title: Localization.appString("wizard.plan.cloud.title", fallback: "Plainsay Cloud"),
                    price: Localization.appString(
                        "wizard.plan.cloud.price", fallback: "US$4 / month"
                    ),
                    features: [
                        Localization.appString(
                            "wizard.plan.cloud.feature1",
                            fallback: "No transcription-model download or preparation"
                        ),
                        Localization.appString(
                            "wizard.plan.cloud.feature2", fallback: "Transcription and Polishing included"
                        ),
                        Localization.appString("wizard.plan.cloud.feature3", fallback: "No API keys to configure"),
                    ],
                    caveats: [
                        Localization.appString("wizard.plan.cloud.caveat1", fallback: "Needs an internet connection"),
                        Localization.appString(
                            "wizard.plan.cloud.caveat2",
                            fallback: "Audio is sent to Plainsay Cloud to be transcribed"
                        ),
                        Localization.appString(
                            "wizard.plan.cloud.caveat3",
                            fallback: "900 transcription minutes in any rolling 30-day window; Local mode is unmetered"
                        ),
                    ],
                    action: { source = .cloud }
                )
            }

            Button {
                source = .remote
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: source == .remote ? "checkmark.circle.fill" : "key.horizontal")
                        .foregroundStyle(source == .remote ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my own cloud API")
                            .foregroundStyle(.primary)
                        Text("Advanced · pick a compatible provider and enter its key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    source == .remote ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(source == .remote ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// Configures whichever method was picked on the Speech step. Split out for
/// the same reason as `LanguageSetupStep`: combined with the plan cards, this
/// much detail forced scrolling on a step no other page in the assistant
/// needs — and "pick a method" and "configure that method" are naturally
/// separate decisions anyway.
private struct ConfigureSpeechSetupStep: View {
    @Binding var source: TranscriptionSource
    @Binding var model: OnDeviceModel
    @Binding var modelWasManuallyChosen: Bool
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    @Binding var asrKeyRevision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupHeading(
                icon: headingIcon,
                colors: headingColors,
                title: headingTitle,
                detail: headingDetail
            )

            switch source {
            case .cloud:
                cloudDetails
            case .onDevice:
                localDetails
            case .remote:
                ownAPIDetails
            }
        }
    }

    private var headingIcon: String {
        switch source {
        case .cloud: "sparkles"
        case .onDevice: "lock.shield.fill"
        case .remote: "key.horizontal.fill"
        }
    }

    private var headingColors: [Color] {
        switch source {
        case .cloud: [.indigo, .blue]
        case .onDevice: [.green, .mint]
        case .remote: [.purple, .blue]
        }
    }

    private var headingTitle: String {
        switch source {
        case .cloud: Localization.appString("wizard.configure.title.cloud", fallback: "Set up Plainsay Cloud")
        case .onDevice: Localization.appString("wizard.configure.title.local", fallback: "Choose a local model")
        case .remote: Localization.appString("wizard.configure.title.byok", fallback: "Bring your own provider")
        }
    }

    private var headingDetail: String {
        switch source {
        case .cloud:
            Localization.appString(
                "wizard.configure.detail.cloud",
                fallback: "Sign in once. Plainsay Cloud supplies speech transcription and Polishing, with no large model to prepare on this Mac."
            )
        case .onDevice:
            Localization.appString(
                "wizard.configure.detail.local",
                fallback: "Recommended multilingual models need about 475–632 MB and can take several minutes to download and prepare the first time."
            )
        case .remote:
            Localization.appString(
                "wizard.configure.detail.byok", fallback: "Audio leaves this Mac and provider charges may apply."
            )
        }
    }

    private var cloudDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            CloudSettingsView(cloud: coordinator.cloud) {
                // Signing in should wake an already-selected Cloud setup. On
                // first run Cloud is still only a draft, so leave the current
                // local engine untouched until Continue commits the choice.
                guard settings.transcriptionSource == .cloud else { return }
                Task { await coordinator.reloadModel() }
            }

            Label(
                "Privacy: recorded audio is uploaded to Plainsay Cloud for transcription and requires an internet connection. Choose Local if audio must never leave this Mac.",
                systemImage: "hand.raised.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.08), Color.blue.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    /// What actually fits `settings.spokenLanguages` right now — recomputed
    /// live as the Refine step (now earlier in the wizard) changes that list.
    private var recommendedModel: OnDeviceModel {
        OnDeviceModel.recommended(for: settings.spokenLanguages)
    }

    private var localDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            ModelChoiceCard(
                isSelected: model == .parakeetTDT06BV3,
                isEnabled: OnDeviceModel.parakeetTDT06BV3.isSupportedOnCurrentHardware,
                icon: "bird.fill",
                colors: [.green, .mint],
                brand: Localization.appString("wizard.model.parakeet.brand", fallback: "NVIDIA"),
                name: Localization.appString("wizard.model.parakeet.name", fallback: "Parakeet TDT 0.6B v3"),
                badge: recommendedModel == .parakeetTDT06BV3
                    ? Localization.appString("wizard.model.parakeet.badge", fallback: "RECOMMENDED") : "",
                detail: OnDeviceModel.parakeetTDT06BV3.isSupportedOnCurrentHardware
                    ? Localization.appString(
                        "wizard.model.parakeet.detail.fit",
                        fallback: "Best fit for Polish + English · multilingual · ~475 MB"
                    )
                    : Localization.appString(
                        "wizard.model.parakeet.detail.unsupported", fallback: "Requires an Apple silicon Mac"
                    ),
                action: {
                    model = .parakeetTDT06BV3
                    modelWasManuallyChosen = true
                }
            )

            whisperChoice

            Divider()

            Toggle("Live preview (experimental)", isOn: $settings.livePreviewEnabled)
                .font(.callout)
            Text("Shows a rough preview of what Plainsay is hearing while you speak, in the HUD. Never changes what actually gets inserted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Local refers to speech recognition and recorded audio. If Polishing is enabled with a cloud provider, transcript text may still be sent to that provider; turn Polishing off for a fully local text path.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private var whisperChoice: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button {
                if model == .parakeetTDT06BV3 {
                    model = .largeV3Turbo
                }
                modelWasManuallyChosen = true
            } label: {
                HStack(spacing: 14) {
                    ModelMark(icon: "waveform", colors: [.indigo, .purple])

                    VStack(alignment: .leading, spacing: 3) {
                        // "NVIDIA" above names the vendor on the Parakeet card;
                        // this should say the same thing at the same altitude,
                        // not repeat the model family name that the headline
                        // right below it already states.
                        HStack(spacing: 8) {
                            Text("OPENAI")
                                .font(.caption2.bold())
                                .tracking(1)
                                .foregroundStyle(.indigo)
                            if recommendedModel != .parakeetTDT06BV3 {
                                Text(Localization.appString("wizard.model.parakeet.badge", fallback: "RECOMMENDED"))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.indigo.opacity(0.13), in: Capsule())
                                    .foregroundStyle(.indigo)
                            }
                        }
                        Text("Whisper")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("A proven model family with several size and language options")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isWhisperSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isWhisperSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isWhisperSelected {
                Divider()

                Picker(
                    "Whisper variant",
                    selection: Binding(
                        get: { model },
                        set: { model = $0; modelWasManuallyChosen = true }
                    )
                ) {
                    ForEach(whisperModels, id: \.self) { option in
                        Text(whisperTitle(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(15)
        .background(Color.primary.opacity(isWhisperSelected ? 0.055 : 0.028), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isWhisperSelected ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.16), lineWidth: isWhisperSelected ? 2 : 1)
        }
    }

    private var ownAPIDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Service", selection: $settings.asrProvider) {
                ForEach(ASRProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            if settings.asrProvider == .custom {
                // The one field this step used to be missing entirely — with
                // no way to name a host, "bring your own provider" meant
                // nothing for anyone not using a preset (Groq/OpenAI/deAPI).
                TextField(
                    "Base URL",
                    text: $settings.asrBaseURL,
                    prompt: Text("https://example.com/v1")
                )
                .textFieldStyle(.roundedBorder)
            }

            ModelField(
                label: Localization.appString("wizard.modelLabel", fallback: "Model"),
                suggestions: settings.asrProvider.suggestedModels,
                placeholder: settings.asrProvider.defaultModel.isEmpty
                    ? Localization.appString("wizard.modelPlaceholder", fallback: "model name")
                    : settings.asrProvider.defaultModel,
                value: $settings.asrModel
            )

            APIKeyField(
                title: Localization.appFormat(
                    "wizard.apiKeyTitle", fallback: "%@ API key", settings.asrProvider.displayName
                ),
                signupURL: settings.asrProvider.signupURL,
                currentKey: settings.apiKey(for: settings.asrProvider),
                onSave: { key in
                    settings.setAPIKey(key, for: settings.asrProvider)
                    asrKeyRevision += 1
                    Task { await coordinator.reloadModel() }
                }
            )
            .id("\(settings.asrProvider.rawValue)-\(asrKeyRevision)")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private var isWhisperSelected: Bool {
        model != .parakeetTDT06BV3
    }

    private var whisperModels: [OnDeviceModel] {
        OnDeviceModel.allCases.filter { $0 != .parakeetTDT06BV3 }
    }

    private func whisperTitle(_ model: OnDeviceModel) -> String {
        switch model {
        case .baseEN:
            Localization.appString("wizard.whisper.base", fallback: "Base · English only · 150 MB")
        case .smallEN:
            Localization.appString("wizard.whisper.small", fallback: "Small · English only · 480 MB")
        case .distilLargeV3Turbo:
            Localization.appString(
                "wizard.whisper.distilLargeV3Turbo", fallback: "Distil Large v3 Turbo · multilingual · 600 MB"
            )
        case .largeV3Turbo:
            Localization.appString(
                "wizard.whisper.largeV3Turbo", fallback: "Large v3 Turbo · multilingual · 632 MB"
            )
        case .parakeetTDT06BV3: model.displayName
        }
    }
}

/// Split out from the Speech step, which had grown tall enough — two plan
/// cards, their details, and this — to force scrolling on a step no other
/// page in the assistant needs. Language and editing are also a genuinely
/// separate decision from *how* audio gets transcribed.
private struct LanguageSetupStep: View {
    /// The uncommitted choice from the Speech step. Reading the persisted
    /// setting here made a fresh Cloud selection look Local until Configure
    /// was finished, and made a switch away from Cloud hide editing controls.
    let speechSource: TranscriptionSource
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    // Doesn't gate Continue — cleanup is optional and falls back to the raw
    // transcript without a key.
    @State private var editingKeyRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupHeading(
                icon: "character.bubble.fill",
                colors: [.purple, .pink],
                title: Localization.appString("wizard.language.title", fallback: "Language & editing"),
                detail: Localization.appString(
                    "wizard.language.detail",
                    fallback: "Tell Plainsay which languages you actually speak, and how it should tidy up the words before inserting them."
                )
            )

            languagesDetails

            // Cloud bundles its own editing pass; only local and BYO
            // transcription need a separate editing provider chosen here.
            if speechSource.bundlesPolishing {
                bundledEditingDetails
            } else {
                editingDetails
            }
        }
    }

    private var languagesDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Languages you speak", systemImage: "globe")
                .font(.headline)

            SpokenLanguagesField(languages: $settings.spokenLanguages)

            Text("Leave empty to auto-detect across every language the model knows. Adding the ones you actually use stops a stray sound from being misheard as a language you don't speak. Put your main language first — it is the one Plainsay falls back to when a transcript comes out in a language you don't speak, and the one it gives to models that can only be told a single language.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private var bundledEditingDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                Localization.appString(
                    "wizard.plan.cloud.feature2", fallback: "Transcription and Polishing included"
                ),
                systemImage: "sparkles"
            )
            .font(.headline)

            Text(
                Localization.appString(
                    "wizard.configure.detail.cloud",
                    fallback: "Sign in once. Plainsay Cloud supplies speech transcription and Polishing, with no large model to prepare on this Mac."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private var editingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Polishing", systemImage: "pencil.and.outline")
                .font(.headline)

            Toggle("Rewrite as written text (removes filler words, fixes punctuation)", isOn: $settings.cleanupEnabled)
                .font(.callout)

            if settings.cleanupEnabled {
                Picker("Polishing service", selection: $settings.cleanupProvider) {
                    ForEach(CleanupProvider.allCases) { provider in
                        Text(
                            provider == .plainsay
                                ? "\(provider.displayName) — \(Localization.appString("cleanup.plainsay.summary", fallback: "included with Cloud"))"
                                : provider.displayName
                        )
                        .tag(provider)
                    }
                }
                .labelsHidden()
                .onChange(of: settings.cleanupProvider) {
                    Task { await coordinator.refreshCloudCleanupIfNeeded() }
                }

                if settings.cleanupProvider == .plainsay {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            Localization.appString(
                                "cleanup.plainsay.noKey", fallback: "No provider key to paste — sign in once"
                            ),
                            systemImage: "checkmark.circle"
                        )
                        Label(
                            Localization.appString(
                                "cleanup.plainsay.subscription",
                                fallback: "Included with an active Plainsay Cloud subscription"
                            ),
                            systemImage: "checkmark.circle"
                        )
                        Label(
                            Localization.appString(
                                "cleanup.plainsay.anySource",
                                fallback: "Works with any transcription source, including fully on-device"
                            ),
                            systemImage: "checkmark.circle"
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)

                    CloudSettingsView(cloud: coordinator.cloud, onCredentialsChanged: {}, showsUsage: false)
                } else {
                    if settings.cleanupProvider == .custom {
                        TextField(
                            "Base URL",
                            text: $settings.cleanupBaseURL,
                            prompt: Text("https://example.com/v1")
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    ModelField(
                        label: Localization.appString("wizard.modelLabel", fallback: "Model"),
                        suggestions: settings.cleanupProvider.suggestedModels,
                        placeholder: settings.cleanupProvider.defaultModel.isEmpty
                            ? Localization.appString("wizard.modelPlaceholder", fallback: "model name")
                            : settings.cleanupProvider.defaultModel,
                        value: $settings.cleanupModel
                    )

                    APIKeyField(
                        title: Localization.appFormat(
                            "wizard.apiKeyTitle", fallback: "%@ API key", settings.cleanupProvider.displayName
                        ),
                        signupURL: settings.cleanupProvider.signupURL,
                        currentKey: settings.apiKey(for: settings.cleanupProvider),
                        onSave: { key in
                            settings.setAPIKey(key, for: settings.cleanupProvider)
                            editingKeyRevision += 1
                        }
                    )
                    .id("\(settings.cleanupProvider.rawValue)-\(editingKeyRevision)")

                    if !settings.cleanupIsConfigured {
                        Text("No key yet — Plainsay will insert the raw transcript until one is saved.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Optional and skippable — voice filtering only helps in a shared room, and
/// nobody should have to record a sample just to get through setup.
private struct VoiceSetupStep: View {
    @Bindable var settings: PlainsaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupHeading(
                icon: "person.wave.2.fill",
                colors: [.teal, .cyan],
                title: Localization.appString("wizard.voice.title", fallback: "Focus on your voice (optional, best effort)"),
                detail: Localization.appString(
                    "wizard.voice.detail",
                    fallback: "Enabling this downloads a separate local filtering model. Plainsay can then try to focus on your enrolled voice locally. If filtering is unavailable or fails, dictation continues with unfiltered audio; a selected Cloud or bring-your-own-provider speech service may then receive that audio."
                )
            )

            VStack(alignment: .leading, spacing: 12) {
                VoiceEnrollmentView(settings: settings)
            }
            .padding(18)
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))

            Label(
                "Skip this if you usually dictate alone — it's off by default and can be set up later in Settings › Speech.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PlanCard: View {
    let isSelected: Bool
    let icon: String
    let colors: [Color]
    let eyebrow: String
    let title: String
    let price: String
    let features: [String]
    /// Real costs of this choice, shown with their own icon rather than a
    /// checkmark. A checkmark reads as "this is good" — putting a tradeoff
    /// like memory use under one would present it as a benefit, which is
    /// exactly the complaint a card that hides its downsides earns.
    var caveats: [String] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ModelMark(icon: icon, colors: colors, size: 52)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(eyebrow)
                        .font(.caption2.bold())
                        .tracking(1)
                        .foregroundStyle(colors.first ?? .accentColor)
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    Text(price)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !caveats.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(caveats, id: \.self) { caveat in
                            Label(caveat, systemImage: "minus.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            LinearGradient(
                colors: isSelected
                    ? [colors[0].opacity(0.12), colors[1].opacity(0.045)]
                    : [Color.primary.opacity(0.035), Color.primary.opacity(0.02)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(isSelected ? colors[0].opacity(0.85) : Color.secondary.opacity(0.16), lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: isSelected ? colors[0].opacity(0.1) : .clear, radius: 12, y: 5)
    }
}

private struct ModelChoiceCard: View {
    let isSelected: Bool
    let isEnabled: Bool
    let icon: String
    let colors: [Color]
    let brand: String
    let name: String
    let badge: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ModelMark(icon: icon, colors: colors)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(brand)
                            .font(.caption2.bold())
                            .tracking(1)
                            .foregroundStyle(colors[0])
                        if !badge.isEmpty {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(colors[0].opacity(0.13), in: Capsule())
                                .foregroundStyle(colors[0])
                        }
                    }
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? colors[0] : Color.secondary.opacity(0.5))
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .background(colors[0].opacity(isSelected ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? colors[0].opacity(0.9) : Color.secondary.opacity(0.16), lineWidth: isSelected ? 2 : 1)
        }
    }
}

private struct ModelMark: View {
    let icon: String
    let colors: [Color]
    var size: CGFloat = 48

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.28)
            )
            .shadow(color: (colors.first ?? .clear).opacity(0.2), radius: 7, y: 3)
    }
}

private struct ShortcutSetupStep: View {
    @Bindable var settings: PlainsaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SetupHeading(
                icon: "keyboard.fill",
                colors: [.orange, .pink],
                title: Localization.appString("wizard.shortcut.title", fallback: "Pick a shortcut"),
                detail: Localization.appString(
                    "wizard.shortcut.detail",
                    fallback: "Use one key from any app. Plainsay listens only while dictation is active."
                )
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    Image(systemName: "command.square.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.binding.localizedDisplayName)
                            .font(.title2.bold())
                        Text("Your dictation shortcut")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Form {
                    Picker("Hotkey", selection: $settings.binding) {
                        ForEach(HotkeyBinding.presets) { preset in
                            Text(preset.localizedDisplayName).tag(preset)
                        }
                    }

                    Picker("Behavior", selection: $settings.hotkeyMode) {
                        ForEach(HotkeyMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 130)
            }
            .padding(20)
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))

            Label(behaviorHint, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

            Label(
                Localization.appString(
                    "dictation.cancelHint",
                    fallback: "Press Esc to cancel the whole dictation without inserting anything."
                ),
                systemImage: "escape"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var behaviorHint: String {
        switch settings.hotkeyMode {
        case .hybrid:
            Localization.appFormat(
                "wizard.shortcut.hint.holdOrTap",
                fallback: "Hold %@ while speaking, or tap once to keep recording and tap again to stop.",
                settings.binding.localizedDisplayName
            )
        case .holdOnly:
            Localization.appFormat(
                "wizard.shortcut.hint.hold", fallback: "Hold %@ while speaking. Release it to stop.",
                settings.binding.localizedDisplayName
            )
        case .toggleOnly:
            Localization.appFormat(
                "wizard.shortcut.hint.tap", fallback: "Tap %@ to start, then tap it again to stop.",
                settings.binding.localizedDisplayName
            )
        }
    }
}

private struct PermissionsSetupStep: View {
    let permissionStatus: PermissionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupHeading(
                icon: "lock.shield.fill",
                colors: [.teal, .blue],
                title: Localization.appString("wizard.permissions.title", fallback: "Allow the essentials"),
                detail: Localization.appString(
                    "wizard.permissions.detail",
                    fallback: """
                    Each permission has one narrow job, described below it. Choose Grant when you \
                    are ready; you can continue even if you finish these later.
                    """
                )
            )

            VStack(spacing: 15) {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        isGranted: permissionStatus.isGranted(permission),
                        onChange: permissionStatus.refresh
                    )

                    if permission != Permission.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(20)
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))

            Label(
                """
                Accessibility and Input Monitoring only take effect in a fresh process, so macOS \
                offers to quit Plainsay when you flip either switch. Let it — setup reopens on \
                this step with your progress intact.
                """,
                systemImage: "arrow.clockwise.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                permissionStatus.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct ReadySetupStep: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    let permissionStatus: PermissionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SetupHeading(
                icon: canDictate ? "checkmark.circle.fill" : readinessIcon,
                colors: canDictate ? [.green, .mint] : [.orange, .yellow],
                title: canDictate
                    ? Localization.appString("wizard.ready.titleReady", fallback: "Plainsay is ready")
                    : readinessTitle,
                detail: readyDetail
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ModelMark(icon: sourceIcon, colors: sourceColors)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("YOUR SPEECH SETUP")
                            .font(.caption2.bold())
                            .tracking(1)
                            .foregroundStyle(sourceColors[0])
                        Text(speechConfigurationTitle)
                            .font(.headline)
                        Text(speechConfigurationDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                ModelLoadStatusView(
                    state: coordinator.modelState,
                    timing: coordinator.modelLoadTiming,
                    onRetry: { Task { await coordinator.retryModel() } },
                    onRestart: restartPlainsay
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 8) {
                Label(dictationInstruction, systemImage: "keyboard.fill")
                    .font(.headline)
                Text("The menu bar icon shows whether Plainsay is ready. If you try the shortcut while a local model is still preparing, its progress appears on screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if case .error(let message) = coordinator.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !permissionStatus.allGranted {
                Label("Some permissions still need attention before dictation can work.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var canDictate: Bool {
        coordinator.isReadyForDictation && permissionStatus.allGranted
    }

    private var readinessIcon: String {
        if case .error = coordinator.phase { return "exclamationmark.triangle.fill" }
        return "hourglass.circle.fill"
    }

    private var readinessTitle: String {
        if case .error = coordinator.phase {
            return Localization.appString("wizard.ready.title.needsAttention", fallback: "Plainsay needs attention")
        }
        return Localization.appString("wizard.ready.title.gettingReady", fallback: "Plainsay is getting ready")
    }

    private var readyDetail: String {
        if canDictate {
            return Localization.appString(
                "wizard.ready.detail.ready",
                fallback: "You can dictate in many Mac apps. If safe insertion is unavailable, the text stays on the clipboard. Settings are always available from the menu bar."
            )
        }
        if case .error = coordinator.phase {
            return Localization.appString(
                "wizard.ready.detail.needsAttention",
                fallback: "Finish the item below before dictation can start. Your setup choice has been saved."
            )
        }
        return Localization.appString(
            "wizard.ready.detail.finishInBackground",
            fallback: "You can finish setup now. Preparation continues in the background, and the menu bar shows when dictation is available."
        )
    }

    private var dictationInstruction: String {
        switch settings.hotkeyMode {
        case .holdOnly:
            Localization.appFormat(
                "wizard.ready.instruction.hold", fallback: "Hold %@ to dictate", settings.binding.localizedDisplayName
            )
        case .toggleOnly:
            Localization.appFormat(
                "wizard.ready.instruction.tap", fallback: "Tap %@ to start and stop", settings.binding.localizedDisplayName
            )
        case .hybrid:
            Localization.appFormat(
                "wizard.ready.instruction.holdOrTap", fallback: "Hold or tap %@ to dictate",
                settings.binding.localizedDisplayName
            )
        }
    }

    private var speechConfigurationTitle: String {
        // Bare vendor name: speechConfigurationDetail right below already
        // states the full model name, so "NVIDIA Parakeet" / "Whisper by
        // OpenAI" here would say the model twice in two consecutive lines.
        switch settings.transcriptionSource {
        case .onDevice:
            settings.model == .parakeetTDT06BV3
                ? Localization.appString("wizard.ready.speechConfig.title.nvidia", fallback: "NVIDIA")
                : Localization.appString("wizard.ready.speechConfig.title.openai", fallback: "OpenAI")
        case .remote: settings.asrProvider.displayName
        case .cloud: Localization.appString("wizard.ready.speechConfig.title.cloud", fallback: "Plainsay Cloud")
        }
    }

    private var speechConfigurationDetail: String {
        switch settings.transcriptionSource {
        case .onDevice:
            Localization.appFormat(
                "wizard.ready.speechConfig.detail.onDevice", fallback: "%@ · %@",
                settings.model.displayName, settings.model.approximateSize
            )
        case .remote:
            Localization.appFormat(
                "wizard.ready.speechConfig.detail.byok", fallback: "Your API · %@", settings.resolvedASRModel
            )
        case .cloud:
            Localization.appString(
                "wizard.ready.speechConfig.detail.cloud",
                fallback: "US$4/month · transcription and Polishing included · no transcription-model download"
            )
        }
    }

    private var sourceIcon: String {
        switch settings.transcriptionSource {
        case .onDevice: settings.model == .parakeetTDT06BV3 ? "bird.fill" : "waveform"
        case .remote: "key.horizontal.fill"
        case .cloud: "cloud.fill"
        }
    }

    private var sourceColors: [Color] {
        switch settings.transcriptionSource {
        case .onDevice: settings.model == .parakeetTDT06BV3 ? [.green, .mint] : [.indigo, .purple]
        case .remote: [.gray, .blue]
        case .cloud: [.indigo, .blue]
        }
    }
}

private struct SetupHeading: View {
    let icon: String
    let colors: [Color]
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ModelMark(icon: icon, colors: colors, size: 62)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
