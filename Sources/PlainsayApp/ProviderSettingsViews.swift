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
