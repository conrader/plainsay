import AppKit
import SwiftUI
import PlainsayCore

/// Settings stay plainly native on purpose. The HUD is where this app spends
/// its personality; a preferences window that fights macOS conventions just
/// makes people hunt for the control they wanted.
struct SettingsView: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    let permissionStatus: PermissionStatus
    let updates: UpdateController

    private enum Tab: Hashable { case speech, general, history, permissions, about }
    @State private var selection: Tab = .speech

    var body: some View {
        // The selection binding is load-bearing, not decoration. Without it,
        // anything that rebuilds the view hierarchy — such as re-checking
        // permissions after returning from System Settings — drops you back on
        // the first tab, which is maddening precisely when you are mid-task.
        TabView(selection: $selection) {
            SpeechSettings(settings: settings, coordinator: coordinator)
                .tabItem { Label("Speech", systemImage: "waveform") }
                .tag(Tab.speech)

            GeneralSettings(settings: settings, coordinator: coordinator, updates: updates)
                .tabItem { Label("General", systemImage: "keyboard") }
                .tag(Tab.general)

            HistoryView(
                history: coordinator.history,
                settings: settings,
                onClearAll: { coordinator.clearAllStoredDictations() },
                onPolicyChange: { coordinator.applyHistoryPolicy() }
            )
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)

            PermissionsSettings(permissionStatus: permissionStatus)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(Tab.permissions)

            AboutSettings(updates: updates)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        // Below roughly 600pt macOS collapses tabs into an overflow menu in
        // the corner, which turns every settings change into a two-click
        // hunt — stay comfortably above that regardless of tab count.
        .frame(minWidth: 660, idealWidth: 660, minHeight: 560, idealHeight: 560)
        // Overrides the window's locale so a language chosen here (rather
        // than the system's) takes effect immediately, no relaunch needed —
        // reads the `@Observable` setting directly so this stays reactive.
        .environment(\.locale, Locale(identifier: Localization.resolvedCode(override: settings.interfaceLanguage)))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    @Bindable var updates: UpdateController

    /// Says plainly what the switch does *and* whether it can currently do it.
    /// A paid feature that silently does nothing for someone without a
    /// subscription reads as a bug, and they would be right to think so.
    private var emailModeFooter: String {
        let explanation = Localization.appString(
            "settings.emailMode.explanation",
            fallback: """
                When you dictate into a mail app, or a webmail compose window, Plainsay lays the                 result out as an email: the greeting on its own line, paragraphs in the body, and                 the sign-off separated from it. It never adds a greeting or a sign-off you did not                 say. Everywhere else, dictation is unchanged.
                """
        )
        guard coordinator.cloud.account?.isActive == true else {
            return explanation + " " + Localization.appString(
                "settings.emailMode.needsSubscription",
                fallback: "This is part of Plainsay Cloud — without an active subscription the switch has no effect."
            )
        }
        return explanation
    }

    var body: some View {
        Form {
            Section {
                Picker("Interface language", selection: $settings.interfaceLanguage) {
                    ForEach(AppLanguage.all) { language in
                        Text(language.displayName).tag(language.code)
                    }
                }
            } footer: {
                Text("Changes the language Plainsay's own menus and windows use — separate from the languages you speak, set under Speech. Applies right away; a window already open may need to be closed and reopened.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    Localization.appString(
                        "settings.emailMode.toggle", fallback: "Format dictation as an email"
                    ),
                    isOn: $settings.emailModeEnabled
                )
            } footer: {
                Text(emailModeFooter)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
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
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(behaviorHint)
                    Text(Localization.appString(
                        "dictation.cancelHint",
                        fallback: "Press Esc to cancel the whole dictation without inserting anything."
                    ))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play a sound when dictation starts and ends", isOn: $settings.playFeedbackSounds)
            }

            Section("Setup") {
                Button("Run Setup Assistant…") {
                    openSetupAssistant()
                }
                Text("Choose a speech model, shortcut, and review the permissions Plainsay needs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecks)
                HStack {
                    Text(Localization.appFormat("settings.version", fallback: "Plainsay %@", updates.currentVersion))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") {
                        updates.checkForUpdates()
                    }
                    .disabled(!updates.canCheck)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(
                    Localization.appFormat(
                        "settings.updates.lastChecked",
                        fallback: "Last checked: %@. Plainsay is distributed outside the App Store, so it has to check for its own updates.",
                        updates.lastCheckDescription
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.binding) { coordinator.settingsChanged() }
        .onChange(of: settings.hotkeyMode) { coordinator.settingsChanged() }
    }

    private var behaviorHint: String {
        switch settings.hotkeyMode {
        case .hybrid:
            Localization.appFormat(
                "settings.behaviorHint.holdOrTap",
                fallback: "Hold %@ and speak, or tap it once to keep recording and tap again to stop.",
                settings.binding.localizedDisplayName
            )
        case .holdOnly:
            Localization.appFormat(
                "settings.behaviorHint.hold",
                fallback: "Hold %@ and speak. Recording ends when you let go.",
                settings.binding.localizedDisplayName
            )
        case .toggleOnly:
            Localization.appFormat(
                "settings.behaviorHint.tap",
                fallback: "Tap %@ to start recording, tap again to stop.",
                settings.binding.localizedDisplayName
            )
        }
    }
}

// MARK: - Speech

private struct SpeechSettings: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    @State private var newTerm = ""
    @State private var asrKeyRevision = 0
    @State private var editingKeyRevision = 0

    var body: some View {
        Form {
            Section {
                Picker("Transcribe", selection: $settings.transcriptionSource) {
                    ForEach(TranscriptionSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
            } footer: {
                Text(sourceExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if settings.transcriptionSource == .onDevice {
                Section("On-device model") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(OnDeviceModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                                .disabled(!model.isSupportedOnCurrentHardware)
                        }
                    }
                    ModelLoadStatusView(
                        state: coordinator.modelState,
                        timing: coordinator.modelLoadTiming,
                        onRetry: { Task { await coordinator.retryModel() } },
                        onRestart: restartPlainsay
                    )
                    Text(
                        Localization.appFormat(
                            "settings.modelDownloadNote", fallback: "%@ download, then it runs entirely on this Mac.",
                            settings.model.approximateSize
                        )
                    )
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if settings.model == .parakeetTDT06BV3 {
                        Text("Automatically handles Polish and English. When Polishing is enabled, vocabulary terms are applied there rather than as decoder hints. NVIDIA Parakeet is provided under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) and runs through FluidAudio.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Live preview (experimental)", isOn: $settings.livePreviewEnabled)
                } footer: {
                    Text("Shows a rough, unedited preview of what Plainsay is hearing while you speak, in the floating HUD. Runs an extra transcription pass every couple of seconds; never changes what actually gets inserted.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if settings.transcriptionSource == .cloud {
                Section("Plainsay Cloud") {
                    CloudSettingsView(cloud: coordinator.cloud) {
                        Task { await coordinator.reloadModel() }
                    }
                }
            } else {
                Section("Transcription service") {
                    Picker("Service", selection: $settings.asrProvider) {
                        ForEach(ASRProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    if settings.asrProvider == .custom {
                        TextField(
                            "Base URL",
                            text: $settings.asrBaseURL,
                            prompt: Text("https://example.com/v1")
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    ModelField(
                        label: Localization.appString("settings.modelLabel", fallback: "Model"),
                        suggestions: settings.asrProvider.suggestedModels,
                        placeholder: settings.asrProvider.defaultModel.isEmpty
                            ? Localization.appString("settings.modelPlaceholder", fallback: "model name")
                            : settings.asrProvider.defaultModel,
                        value: $settings.asrModel
                    )

                    APIKeyField(
                        title: Localization.appFormat(
                            "settings.apiKeyTitle", fallback: "%@ API key", settings.asrProvider.displayName
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

                    if let cost = settings.asrProvider.approximateCostPerHour {
                        Text(cost)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                SpokenLanguagesField(languages: $settings.spokenLanguages)
            } header: {
                Text("Languages you speak")
            } footer: {
                Text("Add the languages you actually use so the model stops guessing among ones you don't — for example, a stray sound read as Russian. The first one is your main language: it is the one models that can only be told a single language are set to, and the one Plainsay falls back to when a transcript comes out in a language you don't speak. Use \u{201C}Make main\u{201D} to change which that is. Leave empty for full auto-detect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                VoiceEnrollmentView(settings: settings)
            } header: {
                Text("Voice recognition")
            }

            Section {
                Toggle("Rewrite transcripts as written text", isOn: $settings.cleanupEnabled)
            } header: {
                Text("Polishing")
            } footer: {
                Text(
                    Localization.appString(
                        "settings.polishingExplanation",
                        fallback: "Asks the selected model to remove filler words and false starts while preserving meaning, tone, and language. Review important text, or turn Polishing off to insert the raw transcript."
                    )
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if settings.cleanupEnabled {
                Section("Polishing provider") {
                    Picker("Service", selection: $settings.cleanupProvider) {
                        ForEach(CleanupProvider.allCases) { provider in
                            Text(
                                provider == .plainsay
                                    ? "\(provider.displayName) — \(Localization.appString("cleanup.plainsay.summary", fallback: "included with Cloud"))"
                                    : provider.displayName
                            )
                            .tag(provider)
                        }
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
                            label: Localization.appString("settings.modelLabel", fallback: "Model"),
                            suggestions: settings.cleanupProvider.suggestedModels,
                            placeholder: settings.cleanupProvider.defaultModel.isEmpty
                                ? Localization.appString("settings.modelPlaceholder", fallback: "model name")
                                : settings.cleanupProvider.defaultModel,
                            value: $settings.cleanupModel
                        )

                        APIKeyField(
                            title: Localization.appFormat(
                                "settings.apiKeyTitle", fallback: "%@ API key", settings.cleanupProvider.displayName
                            ),
                            signupURL: settings.cleanupProvider.signupURL,
                            currentKey: settings.apiKey(for: settings.cleanupProvider),
                            onSave: { key in
                                settings.setAPIKey(key, for: settings.cleanupProvider)
                                editingKeyRevision += 1
                            }
                        )
                        .id("\(settings.cleanupProvider.rawValue)-\(editingKeyRevision)")
                    }
                }

                if settings.cleanupProvider != .plainsay {
                    Section {
                        Text(editingStatusLine)
                            .font(.callout)
                            .foregroundStyle(settings.cleanupIsConfigured ? Color.secondary : Color.orange)
                    }
                }
            }

            Section("Vocabulary") {
                HStack {
                    TextField("Add a name or term", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !termProposals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            Localization.appString(
                                "settings.vocabulary.suggested",
                                fallback: "Suggested from words you keep saying"
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        ForEach(termProposals) { proposal in
                            HStack {
                                Text(proposal.term)
                                Text(Self.occurrenceSummary(proposal.occurrences))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(Localization.appString("settings.vocabulary.accept", fallback: "Add")) {
                                    accept(proposal)
                                }
                                .buttonStyle(.borderless)
                                Button {
                                    dismissProposal(proposal)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(
                                    Localization.appFormat(
                                        "settings.vocabulary.dismiss",
                                        fallback: "Dismiss %@", proposal.term
                                    )
                                )
                            }
                        }
                    }
                }

                if settings.dictionary.normalizedTerms.isEmpty {
                    Text(vocabularyExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.dictionary.normalizedTerms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                remove(term)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(
                                Localization.appFormat("settings.vocabulary.remove", fallback: "Remove %@", term)
                            )
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.model) {
            Task { await coordinator.reloadModel() }
        }
        .onChange(of: settings.transcriptionSource) {
            Task { await coordinator.reloadModel() }
        }
        .onChange(of: settings.asrProvider) {
            Task { await coordinator.reloadModel() }
        }
        .onChange(of: settings.spokenLanguages) {
            Task { await coordinator.reloadModel() }
        }
        .onChange(of: settings.voiceFilterEnabled) {
            Task { await coordinator.reloadVoiceFilterIfNeeded() }
        }
        .onChange(of: settings.cleanupProvider) {
            Task { await coordinator.refreshCloudCleanupIfNeeded() }
        }
    }

    /// Said plainly, because this is the setting that decides whether someone's
    /// voice leaves their machine.
    private var sourceExplanation: String {
        switch settings.transcriptionSource {
        case .onDevice:
            Localization.appString(
                "settings.sourceExplanation.local",
                fallback: "Recorded audio stays on this Mac. Local speech needs a model download and uses Mac storage and memory; optional Polishing may still send transcript text to its configured provider."
            )
        case .remote:
            Localization.appString(
                "settings.sourceExplanation.remote",
                fallback: "Audio is uploaded to a service you hold the key for. No transcription-model download; provider pricing applies."
            )
        case .cloud:
            Localization.appString(
                "settings.sourceExplanation.cloud",
                fallback: "US$4/month: transcription and Polishing are included, with no transcription-model download or keys to manage. Includes up to 900 transcription minutes in any rolling 30-day window. Audio is uploaded to Plainsay Cloud."
            )
        }
    }

    private var editingStatusLine: String {
        guard settings.cleanupIsConfigured else {
            return Localization.appString(
                "settings.editingStatus.notConfigured",
                fallback: "Not configured — Plainsay will insert the raw transcript until a key is saved."
            )
        }
        return Localization.appFormat(
            "settings.editingStatus.configured",
            fallback: "Editing runs through %@ using %@. A failure always falls back to the raw transcript.",
            settings.cleanupProvider.displayName, settings.resolvedCleanupModel
        )
    }

    private var vocabularyExplanation: String {
        if settings.transcriptionSource == .onDevice && !settings.model.supportsDecoderPrompt {
            return Localization.appString(
                "settings.vocabulary.explanation.parakeet",
                fallback: "Add names, jargon, and product names that come out garbled. Parakeet does not accept decoder hints, so Plainsay corrects these spellings itself right after transcribing, whether or not editing is on."
            )
        }
        return Localization.appString(
            "settings.vocabulary.explanation.other",
            fallback: "Add names, jargon, and product names that come out garbled. Plainsay feeds them to the speech model, then corrects any spellings it still gets wrong."
        )
    }

    /// Terms worth offering: recurring in the speaker's own dictations, not
    /// already in the vocabulary, and not previously turned down.
    private var termProposals: [DictionaryProposal] {
        let dismissed = Set(settings.dismissedTermProposals.map { $0.lowercased() })
        return DictionaryProposer.propose(
            from: coordinator.history.records,
            existing: settings.dictionary
        )
        .filter { !dismissed.contains($0.term.lowercased()) }
    }

    private static func occurrenceSummary(_ count: Int) -> String {
        count == 1
            ? Localization.appString("settings.vocabulary.oneDictation", fallback: "in 1 dictation")
            : Localization.appFormat("settings.vocabulary.manyDictations", fallback: "in %d dictations", count)
    }

    private func accept(_ proposal: DictionaryProposal) {
        settings.dictionary.terms.append(proposal.term)
    }

    private func dismissProposal(_ proposal: DictionaryProposal) {
        settings.dismissedTermProposals.append(proposal.term)
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        settings.dictionary.terms.append(term)
        newTerm = ""
    }

    private func remove(_ term: String) {
        settings.dictionary.terms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
    }
}



// MARK: - About

/// Who made this, which build you are running, and how to get at the logs.
///
/// The last one is the reason this tab earns its place rather than being a
/// courtesy page. Every stage of the dictation pipeline records what it did
/// precisely so a dictation that came out wrong can be explained afterwards,
/// and `Log.showCommand` has always carried a comment saying it is surfaced
/// in the UI so nobody has to know the incantation — while being referenced
/// nowhere at all. Diagnostics no one can reach are not diagnostics.
private struct AboutSettings: View {
    @Bindable var updates: UpdateController
    @State private var copiedCommand = false

    private static let website = URL(string: "https://plainsay.app")!
    private static let aboutPage = URL(string: "https://plainsay.app/about/")!
    private static let privacyPage = URL(string: "https://plainsay.app/privacy/")!
    private static let termsPage = URL(string: "https://plainsay.app/terms/")!
    private static let repository = URL(string: "https://github.com/conrader/plainsay")!
    private static let issues = URL(string: "https://github.com/conrader/plainsay/issues")!

    /// A prefilled message to the address on the website.
    ///
    /// Built rather than hardcoded so the version and system in the body are
    /// whatever is actually running, not whatever was true when this was
    /// written.
    private static var feedbackMailto: URL? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let subject = Localization.appFormat(
            "about.feedback.subject", fallback: "Plainsay feedback (%@)", version
        )
        let body = Localization.appFormat(
            "about.feedback.body",
            fallback: """
                Tell us what happened, or what you would like Plainsay to do.

                ---
                Plainsay %@ (%@)
                %@
                """,
            version, build, os
        )
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "hi@plainsay.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plainsay")
                            .font(.title2)
                        Text(
                            Localization.appFormat(
                                "settings.about.version", fallback: "Version %@", updates.currentVersion
                            )
                        )
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        Text("Dictation that never leaves this Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Text(Log.showCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button(
                        copiedCommand
                            ? Localization.appString("settings.about.copied", fallback: "Copied")
                            : Localization.appString("settings.about.copy", fallback: "Copy")
                    ) {
                        copyDiagnosticsCommand()
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(
                    """
                    Every dictation records what the microphone captured, what the model heard, \
                    and whether the paste landed. Run this in Terminal to see it — it is the \
                    fastest way to explain a dictation that came out wrong.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Plainsay on the web") {
                Link("Website", destination: Self.website)
                Link("Who makes Plainsay", destination: Self.aboutPage)
                Link("Source code on GitHub", destination: Self.repository)
                Link("Report an issue on GitHub", destination: Self.issues)
                // Reported by a user: "Report an issue" led only to GitHub,
                // "do którego użytkownik może nie mieć uprawnień. Mało kto poza
                // ludźmi z branży korzysta z GitHuba." Someone who cannot file
                // an issue has no way to tell us anything, so the feedback we
                // get is filtered down to people who already write software.
                //
                // The version and OS are prefilled because they are the two
                // things every report needs and the two nobody thinks to
                // include — and because asking a non-developer to go and find
                // them is how a report turns into no report.
                if let mail = Self.feedbackMailto {
                    Link("Send feedback by email", destination: mail)
                }
            }

            Section {
                Link("Privacy Policy", destination: Self.privacyPage)
                Link("Terms of Service", destination: Self.termsPage)
            } header: {
                Text("Legal")
            } footer: {
                Text(
                    """
                    Made by DMT Sp. z o.o., Poland. Plainsay is open source under the MIT licence; \
                    the on-device speech models carry their own licences, listed on the Speech tab.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func copyDiagnosticsCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Log.showCommand, forType: .string)
        copiedCommand = true
        // Long enough to read, short enough that the button is ready again
        // by the time anyone tries a second time.
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedCommand = false
        }
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
    let permissionStatus: PermissionStatus
    /// Cached grant state. Held as data rather than re-read during `body`, so
    /// refreshing never has to invalidate the view's identity.
    @State private var granted: [Permission: Bool] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        isGranted: granted[permission] ?? false,
                        onChange: refresh
                    )
                }
            } footer: {
                Text("macOS only applies a new grant when Plainsay restarts. Quit and reopen it after changing these.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Poll while this tab is on screen. Grants are made in System Settings,
        // in another process, and there is no notification for them: an
        // accessory app often never "becomes active" again when you come back
        // to an already-open window, so an event-driven refresh silently misses
        // the change and the row keeps saying Grant after you granted it.
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        permissionStatus.refresh()
        let current = Dictionary(
            uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) }
        )
        if current != granted {
            Log.pipeline.info("""
                permissions: mic=\(current[.microphone] ?? false, privacy: .public) \
                ax=\(current[.accessibility] ?? false, privacy: .public) \
                input=\(current[.inputMonitoring] ?? false, privacy: .public)
                """)
            granted = current
        }
    }
}

struct PermissionRow: View {
    let permission: Permission
    let isGranted: Bool
    let onChange: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isGranted, let afterGranting = permission.afterGranting {
                    Label(afterGranting, systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer()
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                // macOS asks once and never again. Once it has, this button
                // can only open System Settings, and calling it "Grant" makes
                // a button that visibly does nothing look broken.
                Button(
                    permission.canStillPrompt
                        ? Localization.appString("permission.action.grant", fallback: "Grant")
                        : Localization.appString("permission.action.openSettings", fallback: "Open Settings…")
                ) {
                    Task {
                        await permission.request()
                        onChange()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
