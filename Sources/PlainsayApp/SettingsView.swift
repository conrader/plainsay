import SwiftUI
import PlainsayCore

/// Settings stay plainly native on purpose. The HUD is where this app spends
/// its personality; a preferences window that fights macOS conventions just
/// makes people hunt for the control they wanted.
struct SettingsView: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator

    private enum Tab: Hashable { case general, speech, cleanup, history, permissions }
    @State private var selection: Tab = .general

    var body: some View {
        // The selection binding is load-bearing, not decoration. Without it,
        // anything that rebuilds the view hierarchy — such as re-checking
        // permissions after returning from System Settings — drops you back on
        // the first tab, which is maddening precisely when you are mid-task.
        TabView(selection: $selection) {
            GeneralSettings(settings: settings, coordinator: coordinator)
                .tabItem { Label("General", systemImage: "keyboard") }
                .tag(Tab.general)

            SpeechSettings(settings: settings, coordinator: coordinator)
                .tabItem { Label("Speech", systemImage: "waveform") }
                .tag(Tab.speech)

            CleanupSettings(settings: settings)
                .tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }
                .tag(Tab.cleanup)

            HistoryView(history: coordinator.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)

            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(Tab.permissions)
        }
        // Wide enough that five tabs fit on the toolbar. Below roughly 600pt
        // macOS collapses them into an overflow menu in the corner, which turns
        // every settings change into a two-click hunt.
        .frame(minWidth: 660, idealWidth: 660, minHeight: 520, idealHeight: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $settings.binding) {
                    ForEach(HotkeyBinding.presets) { preset in
                        Text(preset.displayName).tag(preset)
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
        }
        .formStyle(.grouped)
        .onChange(of: settings.binding) { coordinator.settingsChanged() }
        .onChange(of: settings.hotkeyMode) { coordinator.settingsChanged() }
    }

    private var behaviorHint: String {
        switch settings.hotkeyMode {
        case .hybrid:
            "Hold \(settings.binding.displayName) and speak, or tap it once to keep recording and tap again to stop."
        case .holdOnly:
            "Hold \(settings.binding.displayName) and speak. Recording ends when you let go."
        case .toggleOnly:
            "Tap \(settings.binding.displayName) to start recording, tap again to stop."
        }
    }
}

// MARK: - Speech

private struct SpeechSettings: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    @State private var newTerm = ""
    @State private var asrKeyRevision = 0

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
                        ForEach(WhisperModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    LabeledContent("Status") {
                        ModelStatusLabel(state: coordinator.modelState)
                    }
                    Text("\(settings.model.approximateSize) download, then it runs entirely on this Mac.")
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
                        label: "Model",
                        suggestions: settings.asrProvider.suggestedModels,
                        placeholder: settings.asrProvider.defaultModel.isEmpty
                            ? "model name"
                            : settings.asrProvider.defaultModel,
                        value: $settings.asrModel
                    )

                    APIKeyField(
                        title: "\(settings.asrProvider.displayName) API key",
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

            Section("Vocabulary") {
                HStack {
                    TextField("Add a name or term", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if settings.dictionary.normalizedTerms.isEmpty {
                    Text("Add names, jargon, and product names that come out garbled. Plainsay feeds them to the speech model and uses them to fix spellings afterwards.")
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
                            .accessibilityLabel("Remove \(term)")
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
    }

    /// Said plainly, because this is the setting that decides whether someone's
    /// voice leaves their machine.
    private var sourceExplanation: String {
        switch settings.transcriptionSource {
        case .onDevice:
            "Audio never leaves this Mac. Costs nothing, needs a one-time model download."
        case .remote:
            "Audio is uploaded to a service you hold the key for. No model download, billed per minute."
        case .cloud:
            "Audio is uploaded to Plainsay Cloud. No model download and no keys to manage, for a monthly subscription."
        }
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

private struct ModelStatusLabel: View {
    let state: WhisperKitEngine.LoadState

    var body: some View {
        switch state {
        case .idle:
            Text("Not loaded").foregroundStyle(.secondary)
        case .downloading:
            Text("Downloading…").foregroundStyle(.secondary)
        case .loading:
            Text("Loading…").foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

// MARK: - Cleanup

private struct CleanupSettings: View {
    @Bindable var settings: PlainsaySettings
    @State private var keyRevision = 0

    var body: some View {
        Form {
            Section {
                Toggle("Rewrite transcripts as written text", isOn: $settings.cleanupEnabled)
            } footer: {
                Text("Removes filler words and false starts, fixes punctuation, and keeps your wording. Turn it off to insert the raw transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if settings.cleanupEnabled {
                Section("Provider") {
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
                        label: "Model",
                        suggestions: settings.cleanupProvider.suggestedModels,
                        placeholder: settings.cleanupProvider.defaultModel.isEmpty
                            ? "model name"
                            : settings.cleanupProvider.defaultModel,
                        value: $settings.cleanupModel
                    )

                    APIKeyField(
                        title: "\(settings.cleanupProvider.displayName) API key",
                        signupURL: settings.cleanupProvider.signupURL,
                        currentKey: settings.apiKey(for: settings.cleanupProvider),
                        onSave: { key in
                            settings.setAPIKey(key, for: settings.cleanupProvider)
                            keyRevision += 1
                        }
                    )
                    .id("\(settings.cleanupProvider.rawValue)-\(keyRevision)")
                }

                Section {
                    Text(statusLine)
                        .font(.callout)
                        .foregroundStyle(settings.cleanupIsConfigured ? Color.secondary : Color.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusLine: String {
        guard settings.cleanupIsConfigured else {
            return "Not configured — Plainsay will insert the raw transcript until a key is saved."
        }
        return "Cleanup runs through \(settings.cleanupProvider.displayName) using \(settings.resolvedCleanupModel). A failure always falls back to the raw transcript."
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
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

private struct PermissionRow: View {
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
