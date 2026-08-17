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

    private enum Tab: Hashable { case speech, general, history, permissions }
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

            HistoryView(history: coordinator.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)

            PermissionsSettings(permissionStatus: permissionStatus)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(Tab.permissions)
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
                Text(behaviorHint)
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
                    ModelLoadStatusView(state: coordinator.modelState)
                    Text(
                        Localization.appFormat(
                            "settings.modelDownloadNote", fallback: "%@ download, then it runs entirely on this Mac.",
                            settings.model.approximateSize
                        )
                    )
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if settings.model == .parakeetTDT06BV3 {
                        Text("Automatically handles Polish and English. When cleanup is enabled, vocabulary terms are applied there rather than as decoder hints. NVIDIA Parakeet is provided under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) and runs through FluidAudio.")
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

                Section {
                    Toggle("Live typing (experimental)", isOn: $settings.liveTypingEnabled)
                } footer: {
                    Text("Types each rough pass directly into whatever you're dictating into, live, then corrects it in place once cleanup finishes — instead of one paste at the end. Trades away the guarantee that only clean text ever lands in your document.")
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
                Text("Add the languages you actually use so the model stops guessing among ones you don't — for example, a stray sound read as Russian. Leave empty for full auto-detect.")
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
                Text("Editing")
            } footer: {
                Text("Removes filler words and false starts, fixes punctuation, and keeps your wording. Turn it off to insert the raw transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if settings.cleanupEnabled {
                Section("Editing provider") {
                    Picker("Service", selection: $settings.cleanupProvider) {
                        ForEach(CleanupProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

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

                Section {
                    Text(editingStatusLine)
                        .font(.callout)
                        .foregroundStyle(settings.cleanupIsConfigured ? Color.secondary : Color.orange)
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
    }

    /// Said plainly, because this is the setting that decides whether someone's
    /// voice leaves their machine.
    private var sourceExplanation: String {
        switch settings.transcriptionSource {
        case .onDevice:
            Localization.appString(
                "settings.sourceExplanation.local",
                fallback: "Recorded audio stays on this Mac. Local speech needs a model download and uses Mac storage and memory; optional cleanup may still send transcript text to its configured provider."
            )
        case .remote:
            Localization.appString(
                "settings.sourceExplanation.remote",
                fallback: "Audio is uploaded to a service you hold the key for. No model download, billed per minute."
            )
        case .cloud:
            Localization.appString(
                "settings.sourceExplanation.cloud",
                fallback: "About $3/month: transcription and cleanup are included, with no model download or keys to manage. Audio is uploaded to Plainsay Cloud."
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
            }
            Spacer()
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Grant") {
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
