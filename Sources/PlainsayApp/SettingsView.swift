import SwiftUI
import PlainsayCore

/// Settings stay plainly native on purpose. The HUD is where this app spends
/// its personality; a preferences window that fights macOS conventions just
/// makes people hunt for the control they wanted.
struct SettingsView: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator

    var body: some View {
        TabView {
            GeneralSettings(settings: settings, coordinator: coordinator)
                .tabItem { Label("General", systemImage: "keyboard") }

            SpeechSettings(settings: settings, coordinator: coordinator)
                .tabItem { Label("Speech", systemImage: "waveform") }

            CleanupSettings(settings: settings)
                .tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }

            HistoryView(history: coordinator.history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 420)
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

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $settings.model) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                LabeledContent("Status") {
                    ModelStatusLabel(state: coordinator.modelState)
                }
            } footer: {
                Text("\(settings.model.approximateSize) download, then it runs entirely on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
    @State private var key: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Rewrite transcripts as written text", isOn: $settings.cleanupEnabled)
            } footer: {
                Text("Removes filler words and false starts, fixes punctuation, and keeps your wording. Costs about $0.0004 per dictation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Gemini API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    Button("Save key", action: save)
                        .disabled(key.isEmpty)
                    if settings.hasGeminiKey {
                        Spacer()
                        Button("Remove", role: .destructive) {
                            settings.geminiAPIKey = ""
                            key = ""
                        }
                    }
                }
            } header: {
                Text("Gemini")
            } footer: {
                Text(settings.hasGeminiKey
                     ? "Key stored in your Keychain. Without a working key, Plainsay inserts the raw transcript instead."
                     : "Get a key at aistudio.google.com. Without one, Plainsay inserts the raw transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { key = settings.geminiAPIKey }
    }

    private func save() {
        settings.geminiAPIKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, onChange: { refresh += 1 })
                }
            } footer: {
                Text("macOS only applies a new grant when Plainsay restarts. Quit and reopen it after changing these.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        // Grants happen in System Settings, so re-check whenever we come back.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refresh += 1
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
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
            if permission.isGranted {
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
