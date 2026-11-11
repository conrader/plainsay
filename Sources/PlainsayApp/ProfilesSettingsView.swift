import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PlainsayCore

/// Settings › Profiles: named per-app overrides (FEATURES #4). Default is the
/// rest of Settings and is not editable here. The editor lives in
/// `ProfileEditorView.swift`.
struct ProfilesSettings: View {
    @Bindable var settings: PlainsaySettings
    let coordinator: DictationCoordinator
    @State private var selection: UUID?

    /// Which profiles need the Cloud entitlement. Watching this rather than
    /// every edit means typing a name never triggers an account refresh, while
    /// switching a profile to translation or email layout does (T-238 class).
    private var cloudNeeds: [Bool] { settings.appProfiles.map(\.requestsCloudEntitlement) }

    var body: some View {
        Form {
            Section {
                Text(
                    Localization.appString(
                        "profiles.explanation",
                        fallback: "Pick settings for specific apps. Plainsay chooses the profile from the app in front when you start recording. Everything else uses Default."
                    )
                )
                .font(.callout)
                Text(
                    Localization.appString(
                        "profiles.network",
                        fallback: "Profile names, apps and settings stay on this Mac. Extra vocabulary is sent to remote speech and Polishing providers exactly like your main vocabulary."
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Label(
                    Localization.appString("profiles.default", fallback: "Default (your current settings)"),
                    systemImage: "square.stack"
                )
                .foregroundStyle(.secondary)

                ForEach(settings.appProfiles) { profile in
                    profileRow(profile)
                }

                Button(Localization.appString("profiles.add", fallback: "Add profile"), action: addProfile)
                    .disabled(settings.appProfiles.count >= DictationProfile.maxProfiles)
            } footer: {
                Text(Localization.appString("profiles.limit", fallback: "Up to 20 profiles."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let id = selection, settings.appProfiles.contains(where: { $0.id == id }) {
                ProfileEditor(settings: settings, coordinator: coordinator, profileID: id) {
                    settings.appProfiles.removeAll { $0.id == id }
                    selection = nil
                }
                .id(id)
            }
        }
        .formStyle(.grouped)
        // The account may simply not be refreshed yet this launch; refresh on
        // appear so the Cloud footers below tell the truth.
        .task { await coordinator.appProfilesChanged() }
        .onChange(of: cloudNeeds) { Task { await coordinator.appProfilesChanged() } }
    }

    private func profileRow(_ profile: DictationProfile) -> some View {
        Button {
            selection = profile.id
        } label: {
            HStack {
                Text(profile.name.isEmpty ? "—" : profile.name)
                Spacer()
                Text(ProfileApps.summary(profile.bundleIdentifiers))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if selection == profile.id {
                    Image(systemName: "chevron.down").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func addProfile() {
        let base = Localization.appString("profiles.newName", fallback: "New profile")
        var name = base
        var suffix = 2
        while settings.appProfiles.contains(where: { $0.name == name }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        if let profile = try? settings.appProfiles.addProfile(named: name) {
            selection = profile.id
        }
    }
}

/// Display helpers for bundle identifiers. Reads only Launch Services
/// metadata, never anything the app stores.
@MainActor
enum ProfileApps {
    static func displayName(_ bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func summary(_ bundleIdentifiers: [String]) -> String {
        bundleIdentifiers.map(displayName).joined(separator: ", ")
    }

    struct RunningApp: Identifiable {
        let id: String
        let name: String
    }

    /// Regular (Dock) apps that are running now, other than Plainsay.
    static func running() -> [RunningApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, id.lowercased() != DictationProfile.ownBundleIdentifier,
                      seen.insert(id.lowercased()).inserted
                else { return nil }
                return RunningApp(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Choose app…": any installed app, running or not.
    @MainActor
    static func chooseFromDisk() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
