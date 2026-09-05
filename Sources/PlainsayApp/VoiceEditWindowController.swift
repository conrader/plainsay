import AppKit
import Observation
import SwiftUI
import PlainsayCore

@MainActor
@Observable
final class VoiceEditModel {
    var original: String { didSet { invalidate() } }
    var instruction = "" { didSet { invalidate() } }
    var review: VoiceEditReview?
    var diff: VoiceEditDiff?
    var busy = false
    var detailsReviewed = false
    var message: String?
    var applied = false
    private let selection: SelectedText?
    private let settings: PlainsaySettings
    private var work: Task<Void, Never>?

    init(selection: SelectedText?, settings: PlainsaySettings, message: String?) {
        self.selection = selection
        self.settings = settings
        self.original = selection?.text ?? ""
        self.message = message
    }

    var providerName: String { settings.cleanupProvider.displayName }
    var canReplace: Bool { selection != nil && selection?.text == original && !applied }
    var ready: Bool { review != nil && (!review!.needsAttention || detailsReviewed) && !busy }

    private func invalidate() {
        work?.cancel()
        busy = false
        review = nil
        diff = nil
        detailsReviewed = false
        message = nil
    }

    func preview() {
        work?.cancel()
        let request = VoiceEditRequest(original: original, instruction: instruction)
        do {
            try request.validate()
            let editor = try ProviderFactory.makeEditor(settings)
            busy = true
            message = nil
            review = nil
            diff = nil
            detailsReviewed = false
            work = Task { [weak self] in
                do {
                    let replacement = try await editor.edit(request)
                    try Task.checkCancellation()
                    guard replacement.count <= 24_000 else { throw CleanupError.truncated }
                    let review = VoiceEditReview(original: request.original, replacement: replacement)
                    guard !review.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CleanupError.emptyResponse
                    }
                    self?.review = review
                    self?.diff = VoiceEditDiff(original: request.original, replacement: review.replacement)
                    self?.busy = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.message = error.localizedDescription
                    self?.busy = false
                }
            }
        } catch { message = error.localizedDescription }
    }

    func replace() {
        guard ready, canReplace, let selection, let review else { return }
        busy = true
        work = Task { [weak self] in
            do {
                try await selection.replace(with: review.replacement)
                self?.applied = true
                self?.message = "Replacement sent. Check the text in your app. Your original remains available here."
                self?.busy = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.message = error.localizedDescription
                self?.busy = false
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Copied."
    }

    func cancel() {
        work?.cancel()
        busy = false
    }
}

@MainActor
final class VoiceEditWindowController: NSObject, NSWindowDelegate {
    private let settings: PlainsaySettings
    private var window: NSWindow?
    private var model: VoiceEditModel?

    init(settings: PlainsaySettings) { self.settings = settings }

    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        var selection: SelectedText?
        var message: String?
        do { selection = try SelectedText.capture() }
        catch { message = error.localizedDescription }
        let model = VoiceEditModel(selection: selection, settings: settings, message: message)
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Voice Edit — Plainsay"
        window.contentMinSize = NSSize(width: 720, height: 620)
        window.contentView = NSHostingView(rootView: VoiceEditView(model: model, settings: settings))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}

private struct VoiceEditView: View {
    @Bindable var model: VoiceEditModel
    let settings: PlainsaySettings
    @FocusState private var instructionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "text.cursor").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Say the change. See the difference.").font(.title2.bold())
                    Text("Select text in an app, then press ⌃⌥⌘E to open Voice Edit.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let diff = model.diff {
                HStack(alignment: .top, spacing: 16) {
                    comparison("Original · removed text is struck through", parts: diff.before, before: true)
                    comparison("Your edit · added text is underlined", parts: diff.after, before: false)
                }
                Button("Change the request") { model.review = nil; model.diff = nil; instructionFocused = true }
                    .disabled(model.busy)
            } else {
                Text("Original text").font(.headline)
                TextEditor(text: $model.original)
                    .font(.body).padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .accessibilityLabel("Original text")
                    .disabled(model.busy)
                Text("\(model.original.count) / 12,000 characters").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What should change?").font(.headline)
                TextField("Make it shorter, sound warmer, or translate into Polish…", text: $model.instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...3)
                    .focused($instructionFocused).disabled(model.busy)
                Text("Click here and use your usual dictation key to speak the request, or type it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let review = model.review {
                if review.needsAttention {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Review changed details", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        if !review.removedDetails.isEmpty {
                            Text("Removed or changed: " + review.removedDetails.joined(separator: ", "))
                                .lineLimit(3).help(review.removedDetails.joined(separator: ", "))
                        }
                        if !review.addedDetails.isEmpty {
                            Text("Added or changed: " + review.addedDetails.joined(separator: ", "))
                                .lineLimit(3).help(review.addedDetails.joined(separator: ", "))
                        }
                        Toggle("I reviewed these changes", isOn: $model.detailsReviewed).disabled(model.busy)
                    }
                    .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Names, numbers, and links are checked on this Mac. These checks can miss changes; read the preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Editing with \(model.providerName)").font(.callout.bold())
                    Text("Preview sends the original and request to this provider. Nothing is replaced automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: model.cancel)
                } else if let review = model.review {
                    Menu("Copy") {
                        Button("Copy original") { model.copy(model.original) }
                        Button("Copy edit") { model.copy(review.replacement) }.disabled(!model.ready)
                    }
                    if model.canReplace {
                        Button("Replace selection", action: model.replace)
                            .buttonStyle(.borderedProminent).disabled(!model.ready)
                    } else {
                        Button("Copy edit") { model.copy(review.replacement) }
                            .buttonStyle(.borderedProminent).disabled(!model.ready)
                    }
                } else {
                    Button("Preview edit", action: model.preview)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.instruction.isEmpty)
                }
            }
        }
        .padding(24)
        .onAppear { instructionFocused = !model.original.isEmpty }
    }

    private func comparison(_ title: String, parts: [VoiceEditDiff.Part], before: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                parts.reduce(Text("")) { result, part in
                    result + Text(part.text)
                        .foregroundColor(part.changed ? (before ? .red : .green) : .primary)
                        .strikethrough(part.changed && before)
                        .underline(part.changed && !before)
                }
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Deterministic, offline visual review; starts no dictation or update services.
@MainActor
func renderVoiceEditPreviewIfRequested() -> Bool {
    guard let output = ProcessInfo.processInfo.environment["PLAINSAY_VOICE_EDIT_PREVIEW"] else { return false }
    let defaults = UserDefaults(suiteName: "plainsay.voice-edit-preview")!
    let settings = PlainsaySettings(defaults: defaults)
    settings.cleanupProvider = .gemini
    let model = VoiceEditModel(selection: nil, settings: settings, message: nil)
    model.original = "Hi Anna, I wanted to ask if we could move our meeting to Friday at 10:30. The project budget is $125. Please take a look at https://example.com/brief before we meet. Thanks!"
    model.instruction = "Make this shorter and keep it friendly."
    let result = "Hi Anna, could we meet Friday at 10:30? Our budget is $150. Please review https://example.com/brief beforehand. Thanks!"
    model.review = VoiceEditReview(original: model.original, replacement: result)
    model.diff = VoiceEditDiff(original: model.original, replacement: result)
    // NSHostingView also renders the AppKit-backed text fields and scroll views
    // that SwiftUI's ImageRenderer omits.
    let host = NSHostingView(rootView: VoiceEditView(model: model, settings: settings)
        .frame(width: 860, height: 760).background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        exit(1)
    }
    do { try png.write(to: URL(fileURLWithPath: output)) } catch { exit(1) }
    exit(0)
}
