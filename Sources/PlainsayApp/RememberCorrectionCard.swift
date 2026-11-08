import Observation
import SwiftUI
import PlainsayCore

/// The "Remember this correction?" state behind the card in the correction
/// window (SPEC.fixed.md §2.2). The decisions live in Core
/// (`RememberCorrectionOffer.make`, `ReplacementRuleSet.saveCheck`); this
/// holds only what the card shows and writes the user's choice to Settings.
@MainActor
@Observable
final class RememberCorrectionModel {
    enum Stage: Equatable {
        case hidden
        case offer(warning: ReplacementWarning?)
        case editing
        case saved(UUID)
        case inverse(ReplacementRule)
        case note(String)
    }

    private let settings: PlainsaySettings
    private(set) var stage: Stage = .hidden
    var from = "" { didSet { clearProblem() } }
    var to = "" { didSet { clearProblem() } }
    /// Unchecked by default (Q2): ticking it sends the term to remote speech
    /// and Polishing hints and turns on fuzzy repair for it.
    var addToVocabulary = false
    private(set) var problem: String?
    private(set) var confirmation: ReplacementRuleSaveCheck?

    init(settings: PlainsaySettings) {
        self.settings = settings
    }

    /// Global plus app-profile terms: the validator must not let a rule fight
    /// any Vocabulary in effect (SPEC §3.3).
    var vocabulary: [String] {
        settings.dictionary.terms + settings.appProfiles.flatMap(\.extraTerms)
    }

    var showsVocabularyOption: Bool {
        let term = to.trimmingCharacters(in: .whitespacesAndNewlines)
        return !term.isEmpty && !ReplacementRuleSet.vocabulary(settings.dictionary.terms, contains: term)
    }

    /// Called only after `applyCorrection` succeeded for a local `.replace`.
    func present(_ offer: RememberCorrectionOffer?) {
        reset()
        switch offer {
        case .remember(let matched, let target, let warning)?:
            from = matched
            to = target
            stage = .offer(warning: warning)
        case .inverse(let rule)?:
            stage = .inverse(rule)
        case nil:
            break
        }
    }

    /// A new instruction or preview hides the offer. A saved rule keeps its
    /// Forget button (an undo preview does not delete it either, §2.2 item 5).
    func dismissOffer() {
        if case .saved = stage { return }
        reset()
    }

    func reset() {
        stage = .hidden
        addToVocabulary = false
        problem = nil
        confirmation = nil
    }

    func beginEditing() { stage = .editing }

    func save() {
        let check = settings.replacementRules.saveCheck(from: from, to: to, vocabulary: vocabulary)
        switch check {
        case .rejected(let reason):
            problem = RuleText.rejection(reason, from: from)
            return
        case .needsConfirmation where confirmation != check:
            confirmation = check
            return
        case .ready, .needsConfirmation:
            break
        }
        var rules = settings.replacementRules
        guard let rule = rules.save(from: from, to: to, source: .correction, vocabulary: vocabulary) else {
            problem = RuleText.rejection(.limitReached, from: from)
            return
        }
        settings.replacementRules = rules
        if addToVocabulary, showsVocabularyOption {
            settings.dictionary.terms.append(rule.to)
        }
        addToVocabulary = false
        confirmation = nil
        stage = .saved(rule.id)
    }

    /// Removes only the rule. A Vocabulary term added with it stays: that is
    /// a separate, visible entry in Settings → Speech → Vocabulary.
    func forget() {
        guard case .saved(let id) = stage else { return }
        settings.replacementRules.remove(id: id)
        stage = .note(RuleText.forgotten)
    }

    func turnOffInverse() {
        guard case .inverse(let rule) = stage else { return }
        settings.replacementRules.setEnabled(false, id: rule.id)
        stage = .note(RuleText.turnedOff)
    }

    /// The short-word warning for the fields as edited.
    var editWarning: ReplacementWarning? {
        let assessment = ReplacementRuleValidator.assess(from: from, to: to, rules: settings.replacementRules,
                                                         vocabulary: vocabulary)
        if case .offerWithWarning(let warning) = assessment { return warning }
        return nil
    }

    /// Text for the pending confirmation, if Save is waiting for one.
    var confirmationText: String? {
        guard case .needsConfirmation(let caution, let replaces)? = confirmation else { return nil }
        let parts = [caution.map { RuleText.caution($0, from: from) },
                     replaces.map { RuleText.duplicate($0.from) }].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    var saveTitle: String {
        guard case .needsConfirmation(let caution, _)? = confirmation else { return RuleText.save }
        return caution == nil ? RuleText.replace : RuleText.saveAnyway
    }

    private func clearProblem() {
        problem = nil
        confirmation = nil
    }
}

/// The inline card under the correction window's status message. None of its
/// buttons is the default button, so Return never saves a rule.
struct RememberCorrectionCard: View {
    @Bindable var model: RememberCorrectionModel

    var body: some View {
        switch model.stage {
        case .hidden:
            EmptyView()
        case .offer(let warning):
            card {
                Text(RuleText.offerTitle).font(.headline)
                Text(verbatim: "\(model.from) → \(model.to)").font(.body.monospaced()).textSelection(.enabled)
                Text(RuleText.offerBody(from: model.from, to: model.to)).font(.callout).foregroundStyle(.secondary)
                if let warning { warningLabel(RuleText.warning(warning)) }
                HStack {
                    Button(RuleText.remember, action: model.beginEditing)
                    Button(RuleText.notNow, action: model.reset)
                }
            }
        case .editing:
            card { editor }
        case .saved:
            card {
                Text(RuleText.saved).font(.callout)
                Button(RuleText.forget, action: model.forget)
            }
        case .inverse(let rule):
            card {
                Text(RuleText.inverse(from: rule.from, to: rule.to)).font(.callout)
                HStack {
                    Button(RuleText.turnOff, action: model.turnOffInverse)
                    Button(RuleText.keep, action: model.reset)
                }
            }
        case .note(let text):
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var editor: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text(RuleText.fromLabel)
                TextField(RuleText.fromLabel, text: $model.from).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(RuleText.fromLabel)
            }
            GridRow {
                Text(RuleText.toLabel)
                TextField(RuleText.toLabel, text: $model.to).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(RuleText.toLabel)
            }
        }
        if let warning = model.editWarning { warningLabel(RuleText.warning(warning)) }
        Text(RuleText.scope).font(.caption).foregroundStyle(.secondary)
        Text(RuleText.inflection).font(.caption).foregroundStyle(.secondary)
        if model.showsVocabularyOption {
            Toggle(RuleText.addToVocabulary(model.to.trimmingCharacters(in: .whitespacesAndNewlines)),
                   isOn: $model.addToVocabulary)
            if model.addToVocabulary {
                Text(RuleText.vocabularyFuzzy).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let problem = model.problem { warningLabel(problem) }
        if let confirmation = model.confirmationText { warningLabel(confirmation) }
        HStack {
            Button(model.saveTitle, action: model.save)
            Button(RuleText.cancel, action: model.reset)
        }
    }

    private func warningLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
