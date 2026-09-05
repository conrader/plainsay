import AppKit
import Observation
import SwiftUI
import PlainsayCore

@MainActor
@Observable
final class DictationCorrectionModel {
    let dictation: LastDictation
    let coordinator: DictationCoordinator
    let settings: PlainsaySettings
    var instruction = "" { didSet { clearPreview() } }
    var proposal: DictationCorrectionProposal?
    var review: VoiceEditReview?
    var busy = false
    var ownsCapture = false
    var detailsReviewed = false
    var message: String?
    private var work: Task<Void, Never>?

    init(dictation: LastDictation, coordinator: DictationCoordinator, settings: PlainsaySettings) {
        self.dictation = dictation
        self.coordinator = coordinator
        self.settings = settings
    }

    var recording: Bool { ownsCapture && coordinator.phase == .recording }
    var canApply: Bool {
        !busy && !ownsCapture && coordinator.lastDictation === dictation && dictation.canReplace
            && proposal?.revision == dictation.revision
            && (proposal?.isUndo == true || review?.needsAttention != true || detailsReviewed)
    }

    private func clearPreview() {
        work?.cancel()
        busy = false
        proposal = nil
        review = nil
        detailsReviewed = false
        message = nil
    }

    func toggleRecording() {
        if ownsCapture {
            if recording { coordinator.finishCorrectionCapture() }
            return
        }
        guard !busy, coordinator.lastDictation === dictation else {
            message = DictationCorrectionError.stale.localizedDescription
            return
        }
        clearPreview()
        ownsCapture = true
        let started = coordinator.beginCorrectionCapture { [weak self] result in
            guard let self else { return }
            self.ownsCapture = false
            switch result {
            case .success(let command):
                self.instruction = command
                do {
                    let parsed = try DictationCorrectionCommand.parse(command)
                    // Broad rewriting sends the original to the selected editing
                    // provider only after the user chooses Preview correction.
                    if case .rewrite = parsed {
                        self.message = self.settings.cleanupProvider == .plainsay
                            ? VoiceEditError.cloudUnsupported.localizedDescription
                            : "Choose Preview correction to send this request and the dictation to \(self.settings.cleanupProvider.displayName)."
                    } else { self.preview() }
                } catch { self.message = error.localizedDescription }
            case .failure(let error): self.message = error.localizedDescription
            }
        }
        if !started {
            ownsCapture = false
            message = coordinator.lastErrorMessage ?? "Speech is not ready. Finish setup or type your correction below."
        }
    }

    func preview() {
        guard !ownsCapture, coordinator.lastDictation === dictation else {
            message = DictationCorrectionError.stale.localizedDescription
            return
        }
        clearPreview()
        do {
            let command = try DictationCorrectionCommand.parse(instruction)
            let isUndo = command == .undo
            if let replacement = try command.localReplacement(in: dictation.text, undoText: dictation.undoText) {
                show(replacement, isUndo: isUndo)
                return
            }
            let editor = try ProviderFactory.makeEditor(settings)
            let request = VoiceEditRequest(original: dictation.text, instruction: instruction)
            try request.validate()
            let revision = dictation.revision
            busy = true
            work = Task { [weak self] in
                do {
                    let replacement = try await editor.edit(request)
                    try Task.checkCancellation()
                    guard let self else { return }
                    guard self.coordinator.lastDictation === self.dictation, self.dictation.revision == revision else {
                        throw DictationCorrectionError.stale
                    }
                    guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CleanupError.emptyResponse }
                    guard replacement.count <= 24_000 else { throw CleanupError.truncated }
                    self.show(replacement, isUndo: false)
                    self.busy = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.message = error.localizedDescription
                    self?.busy = false
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func show(_ replacement: String, isUndo: Bool) {
        proposal = dictation.proposal(replacement: replacement, isUndo: isUndo)
        review = VoiceEditReview(original: dictation.text, replacement: replacement)
        if !dictation.canReplace {
            message = "Plainsay could not verify where this dictation landed. Copy the correction and replace the original manually."
        }
    }

    func apply() {
        guard canApply, let proposal else { return }
        busy = true
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.applyCorrection(proposal, to: self.dictation)
                self.message = proposal.isUndo ? "Undone in the original app." : "Corrected in the original app."
                self.proposal = nil
                self.review = nil
                self.busy = false
            } catch {
                self.message = error.localizedDescription
                self.busy = false
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func undoPreview() {
        instruction = "Undo that"
        preview()
    }

    func copy() {
        guard let proposal, !proposal.replacement.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proposal.replacement, forType: .string)
        message = "Copied. Select the original dictation and paste this correction."
    }

    func cancel() {
        work?.cancel()
        if ownsCapture { coordinator.cancelCorrectionCapture() }
        ownsCapture = false
        busy = false
    }
}

@MainActor
final class DictationCorrectionWindow: NSObject, NSWindowDelegate {
    private let coordinator: DictationCoordinator
    private let settings: PlainsaySettings
    private var window: NSWindow?
    private var model: DictationCorrectionModel?

    init(coordinator: DictationCoordinator, settings: PlainsaySettings) {
        self.coordinator = coordinator
        self.settings = settings
    }

    func show(record: Bool = false) {
        guard let dictation = coordinator.lastDictation, !coordinator.isApplyingCorrection else { return }
        if coordinator.phase.isBusy && model?.ownsCapture != true { return }
        if model?.dictation !== dictation {
            window?.close()
            model = nil
        }
        if window == nil {
            let model = DictationCorrectionModel(dictation: dictation, coordinator: coordinator, settings: settings)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Correct Last Dictation — Plainsay"
            window.contentMinSize = NSSize(width: 660, height: 620)
            window.contentView = NSHostingView(rootView: DictationCorrectionView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.model = model
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if record { model?.toggleRecording() }
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}

private struct DictationCorrectionView: View {
    @Bindable var model: DictationCorrectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Fix what you just said", systemImage: "arrow.uturn.backward.circle")
                .font(.title2.bold())
            Text("Press ⌃⌥⌘R, say the correction, then press it again. No text selection needed.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Last dictation").font(.headline)
                ScrollView {
                    Text(model.proposal?.original ?? model.dictation.text)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(12)
                }
                .frame(minHeight: 70, maxHeight: .infinity)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                TextField("Change Tuesday to Thursday, or say ‘undo that’…", text: $model.instruction, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder).disabled(model.busy || model.ownsCapture)
                    .accessibilityLabel("Correction instruction")
                Button(action: model.toggleRecording) {
                    Label(model.recording ? "Stop" : "Speak", systemImage: model.recording ? "stop.fill" : "mic.fill")
                }
                .disabled(model.busy || (model.ownsCapture && !model.recording))
            }
            if model.ownsCapture {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.recording ? "Listening to your correction… Esc cancels." : "Transcribing your correction…")
                    Spacer()
                    Button("Cancel", action: model.cancel)
                }
            }

            if let proposal = model.proposal {
                Text(proposal.isUndo ? "Undo preview" : "Correction preview").font(.headline)
                ScrollView {
                    Text(proposal.replacement.isEmpty ? "This will remove the last dictation." : proposal.replacement)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
                }
                .frame(minHeight: 60, maxHeight: .infinity)
                .background(.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                if let review = model.review, review.needsAttention, !proposal.isUndo {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Check changed details", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text((review.removedDetails + review.addedDetails).joined(separator: " · "))
                            .font(.caption).lineLimit(2)
                            .help((review.removedDetails + review.addedDetails).joined(separator: " · "))
                        Toggle("I reviewed these changes", isOn: $model.detailsReviewed)
                    }
                }
            }

            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Divider()
            Text(model.settings.cleanupProvider == .plainsay
                ? "Change/replace and undo run on this Mac. Other rewriting needs a separate Polishing provider. Speech uses your selected transcription service."
                : "Change/replace and undo run on this Mac. Other requests use \(model.settings.cleanupProvider.displayName) when you preview. Speech uses your selected transcription service.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Undo last change", action: model.undoPreview)
                    .disabled(model.dictation.undoText == nil || model.busy || model.ownsCapture)
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: model.cancel)
                } else if let proposal = model.proposal {
                    Button("Copy correction", action: model.copy).disabled(proposal.replacement.isEmpty)
                    if model.dictation.canReplace {
                        Button(proposal.isUndo ? "Apply undo" : "Replace last dictation", action: model.apply)
                            .buttonStyle(.borderedProminent).disabled(!model.canApply)
                    }
                } else {
                    Button("Preview correction", action: model.preview)
                        .buttonStyle(.borderedProminent).disabled(model.instruction.isEmpty || model.ownsCapture)
                }
            }
        }
        .padding(24)
    }
}

@MainActor
private final class CorrectionPreviewTarget: DictationReplacementTarget {
    let replacedText = ""
    func replace(with text: String) async throws { throw DictationCorrectionError.stale }
}

/// An offline fixture for reviewing layout without recording or editing an app.
@MainActor
func renderCorrectionPreviewIfRequested() -> Bool {
    guard let output = ProcessInfo.processInfo.environment["PLAINSAY_CORRECTION_PREVIEW"] else { return false }
    let settings = PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.correction-preview")!)
    settings.cleanupProvider = .plainsay
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("plainsay-correction-preview")
    let coordinator = DictationCoordinator(settings: settings,
        history: TranscriptHistory(directory: root.appendingPathComponent("history")),
        pendingAudio: PendingAudioStore(directory: root.appendingPathComponent("audio")))
    let dictation = LastDictation(text: "Hi Anna, let's meet on Tuesday at 10:30. The project budget is $125.", target: CorrectionPreviewTarget())
    let model = DictationCorrectionModel(dictation: dictation, coordinator: coordinator, settings: settings)
    model.instruction = "Change $125 to $150."
    let replacement = "Hi Anna, let's meet on Tuesday at 10:30. The project budget is $150."
    model.proposal = dictation.proposal(replacement: replacement)
    model.review = VoiceEditReview(original: dictation.text, replacement: replacement)
    let host = NSHostingView(rootView: DictationCorrectionView(model: model)
        .frame(width: 760, height: 680).background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: output)) } catch { exit(1) }
    exit(0)
}
