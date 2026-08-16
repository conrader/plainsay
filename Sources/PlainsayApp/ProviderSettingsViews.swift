import SwiftUI
import PlainsayCore

/// A key field plus a "get one" link.
///
/// Keys are held per provider, so the field repopulates when you switch back
/// rather than making you dig the key out again.
struct APIKeyField: View {
    let title: String
    let signupURL: String?
    let currentKey: String
    let onSave: (String) -> Void

    @State private var draft = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(title, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(saved ? "Saved" : "Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 10) {
                if !currentKey.isEmpty {
                    Label("Key stored in Keychain", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                if let signupURL, let url = URL(string: signupURL) {
                    Link("Get a key", destination: url)
                        .font(.callout)
                }
                Spacer()
                if !currentKey.isEmpty {
                    Button("Remove", role: .destructive) {
                        onSave("")
                        draft = ""
                        saved = false
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
        }
        .onAppear { draft = currentKey }
        .onChange(of: currentKey) { _, new in draft = new }
    }

    private func save() {
        onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        saved = true
    }
}

/// Lets someone name the languages they actually speak, so a speech model
/// auto-detecting across ~99 languages never lands on one they never use.
///
/// The first language added is the one engines force when they need a
/// single choice — remote/cloud ASR, or an on-device retry after a
/// mismatched auto-detection — so order matters and is shown.
struct SpokenLanguagesField: View {
    @Binding var languages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if languages.isEmpty {
                Text("Auto-detecting across every language the model knows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(languages, id: \.self) { code in
                    HStack {
                        Text(SupportedLanguage.named(code))
                        if code == languages.first {
                            Text("primary")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            languages.removeAll { $0 == code }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(SupportedLanguage.named(code))")
                    }
                }
            }

            Menu {
                ForEach(SupportedLanguage.all.filter { !languages.contains($0.code) }) { language in
                    Button(language.name) { languages.append(language.code) }
                }
            } label: {
                Label("Add a language", systemImage: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// Free-text model name with suggestions.
///
/// A picker alone would go stale the week a provider ships a new model, so the
/// field is authoritative and the menu is a shortcut.
struct ModelField: View {
    let label: String
    let suggestions: [String]
    let placeholder: String
    @Binding var value: String

    var body: some View {
        HStack {
            TextField(label, text: $value, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)

            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { model in
                        Button(model) { value = model }
                    }
                    Divider()
                    Button("Use provider default") { value = "" }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}
