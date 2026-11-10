import AppKit
import SwiftUI
import PlainsayCore

/// One profile's fields, as Form sections inside `ProfilesSettings`. Every
/// field starts at "Same as Default". Writes go through `normalized()`, so
/// Polishing Off can never be stored together with an email or translation
/// override it would silently ignore.
struct ProfileEditor: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    let profileID: UUID
    let onDelete: () -> Void

    @State private var newTerm = ""
    @State private var pendingMove: PendingMove?

    private struct PendingMove: Identifiable {
        let bundleIdentifier: String
        let ownerName: String
        var id: String { bundleIdentifier }
    }

    private var profile: Binding<DictationProfile> {
        Binding(
            get: { settings.appProfiles.first { $0.id == profileID } ?? DictationProfile(id: profileID, name: "") },
            set: { updated in
                guard let index = settings.appProfiles.firstIndex(where: { $0.id == profileID }) else { return }
                settings.appProfiles[index] = updated.normalized()
            }
        )
    }

    private var inherit: String { Localization.appString("profiles.inherit", fallback: "Same as Default") }
    private var isEntitled: Bool { coordinator.cloud.account?.isActive == true }
    private var polishingOff: Bool { profile.wrappedValue.polishing == .off }
    /// The Default's Polishing as the factory will build it (§2.2): off or a
    /// missing key means email layout and translation cannot run at all.
    private var readiness: PolishingReadiness { ProviderFactory.polishingReadiness(settings) }

    private var missingKeyProvider: CleanupProvider? {
        if case .missingKey(let provider) = readiness { provider } else { nil }
    }

    var body: some View {
        Section {
            TextField(Localization.appString("profiles.name", fallback: "Name"), text: profile.name)
        }
        appsSection
        vocabularySection
        processingSection
        Section {
            Picker(Localization.appString("profiles.output", fallback: "After dictation"), selection: profile.output) {
                Text(verbatim: "\(inherit) (\(Localization.appString("profiles.output.paste", fallback: "Paste")))")
                    .tag(DictationProfile.OutputOverride.inherit)
                Text(Localization.appString("profiles.output.copy", fallback: "Copy only"))
                    .tag(DictationProfile.OutputOverride.copyOnly)
            }
            Button(Localization.appString("profiles.delete", fallback: "Delete profile"), role: .destructive, action: onDelete)
        }
        .alert(
            pendingMove.map {
                Localization.appFormat(
                    "profiles.moveApp", fallback: "%@ is already in “%@”. Move it here?",
                    ProfileApps.displayName($0.bundleIdentifier), $0.ownerName
                )
            } ?? "",
            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
            presenting: pendingMove
        ) { move in
            Button(Localization.appString("profiles.move", fallback: "Move")) { assign(move.bundleIdentifier) }
            Button(Localization.appString("profiles.cancel", fallback: "Cancel"), role: .cancel) {}
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        Section(Localization.appString("profiles.apps", fallback: "Apps")) {
            ForEach(profile.wrappedValue.bundleIdentifiers, id: \.self) { bundleIdentifier in
                HStack {
                    Text(ProfileApps.displayName(bundleIdentifier))
                    Text(bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        profile.wrappedValue.bundleIdentifiers.removeAll { $0 == bundleIdentifier }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Localization.appFormat("spokenLanguages.remove", fallback: "Remove %@",
                                                               ProfileApps.displayName(bundleIdentifier)))
                }
            }
            Menu(Localization.appString("profiles.addApp", fallback: "Add app…")) {
                ForEach(ProfileApps.running()) { app in
                    Button(app.name) { request(app.id) }
                }
                Divider()
                Button(Localization.appString("profiles.chooseApp", fallback: "Choose app…")) {
                    if let id = ProfileApps.chooseFromDisk() { request(id) }
                }
            }
            .disabled(profile.wrappedValue.bundleIdentifiers.count >= DictationProfile.maxApps)
        }
    }

    /// An app belongs to one profile: ask before moving it from another.
    private func request(_ bundleIdentifier: String) {
        if let owner = settings.appProfiles.owner(of: bundleIdentifier, excluding: profileID) {
            pendingMove = PendingMove(bundleIdentifier: bundleIdentifier, ownerName: owner.name)
        } else {
            assign(bundleIdentifier)
        }
    }

    private func assign(_ bundleIdentifier: String) {
        try? settings.appProfiles.assign(bundleIdentifier, to: profileID)
    }

    // MARK: Vocabulary

    private var vocabularySection: some View {
        Section {
            HStack {
                TextField(Localization.appString("profiles.addTerm", fallback: "Add a term"), text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty
                        || profile.wrappedValue.extraTerms.count >= DictationProfile.maxTerms)
            }
            ForEach(profile.wrappedValue.extraTerms, id: \.self) { term in
                HStack {
                    Text(term)
                    Spacer()
                    Button {
                        profile.wrappedValue.extraTerms.removeAll { $0 == term }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Localization.appFormat("spokenLanguages.remove", fallback: "Remove %@", term))
                }
            }
        } header: {
            Text(Localization.appString("profiles.vocabulary", fallback: "Extra vocabulary"))
        } footer: {
            let overflow = profile.wrappedValue.overflowCount(defaultDictionary: settings.dictionary)
            if overflow > 0 {
                Text(
                    Localization.appFormat(
                        "profiles.vocabulary.overflow",
                        fallback: "%d terms may not fit in the speech hint; they still get local corrections.",
                        overflow
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func addTerm() {
        try? settings.appProfiles.addTerm(newTerm, to: profileID)
        newTerm = ""
    }

    // MARK: Polishing, email layout, translation

    private var processingSection: some View {
        Section {
            Picker("Polishing", selection: profile.polishing) {
                Text(inherit).tag(DictationProfile.PolishingOverride.inherit)
                Text(Localization.appString("profiles.polishing.off", fallback: "Off for this app"))
                    .tag(DictationProfile.PolishingOverride.off)
            }
            // Email and translation run inside Polishing. A profile's own Off
            // greys them; a Default whose Polishing cannot run (off, or no key
            // for the provider) hides them and says why, rather than offering
            // a translation that would silently come out untranslated.
            if readiness.offersStyles {
                Picker(Localization.appString("profiles.email", fallback: "Email layout"), selection: profile.emailLayout) {
                    Text(inherit).tag(DictationProfile.LayoutOverride.inherit)
                    Text(Localization.appString("profiles.email.composers", fallback: "In mail composers"))
                        .tag(DictationProfile.LayoutOverride.composers)
                    Text(Localization.appString("profiles.off", fallback: "Off")).tag(DictationProfile.LayoutOverride.off)
                }
                .disabled(polishingOff)
                Picker(Localization.appString("profiles.translation", fallback: "Translation"), selection: profile.translation) {
                    Text(inherit).tag(DictationProfile.TranslationOverride.inherit)
                    Text(Localization.appString("profiles.off", fallback: "Off")).tag(DictationProfile.TranslationOverride.off)
                    ForEach(translationTargets, id: \.self) { code in
                        Text(verbatim: "→ \(SupportedLanguage.named(code))").tag(DictationProfile.TranslationOverride.target(code))
                    }
                }
                .disabled(polishingOff)
            }
        } footer: {
            if let provider = missingKeyProvider, !polishingOff {
                Text(
                    Localization.appFormat(
                        "profiles.needsKey",
                        fallback: "Email layout and translation need Polishing, and %@ has no API key. Add one in Settings › Speech › Polishing.",
                        provider.displayName
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if polishingOff || readiness == .off {
                Text(Localization.appString("profiles.needsPolishing", fallback: "Email layout and translation need Polishing turned on."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !isEntitled {
                // Enabled on purpose, like the global email switch: the account
                // may only be unrefreshed, and the stored value is ignored at
                // runtime without the entitlement anyway.
                Text(Localization.appString("profiles.cloudRequired", fallback: "Requires Plainsay Cloud."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Same targets as the menu bar (spoken languages plus English), plus the
    /// profile's own target if it is none of those.
    private var translationTargets: [String] {
        var codes = settings.spokenLanguages.map(SupportedLanguage.primaryCode)
        if !codes.contains("en") { codes.append("en") }
        if case .target(let code) = profile.wrappedValue.translation, !codes.contains(code) { codes.append(code) }
        return codes
    }
}
