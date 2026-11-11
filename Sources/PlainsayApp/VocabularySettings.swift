import AppKit
import SwiftUI
import PlainsayCore

// MARK: - Speech: Vocabulary

extension SpeechSettings {
    var vocabularySection: some View {
        Section("Vocabulary") {
            HStack {
                TextField("Add a name or term", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !termProposals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        Localization.appString(
                            "settings.vocabulary.suggested",
                            fallback: "Suggested from words you keep saying"
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    ForEach(termProposals) { proposal in
                        HStack {
                            Text(proposal.term)
                            Text(Self.occurrenceSummary(proposal.occurrences))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(Localization.appString("settings.vocabulary.accept", fallback: "Add")) {
                                accept(proposal)
                            }
                            .buttonStyle(.borderless)
                            Button {
                                dismissProposal(proposal)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(
                                Localization.appFormat(
                                    "settings.vocabulary.dismiss",
                                    fallback: "Dismiss %@", proposal.term
                                )
                            )
                        }
                    }
                }
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
        .onAppear(perform: pruneRetiredRuleTargets)
        // Retried while open: a prune refused during work, or History
        // retention dropping records, must not leave the overflow fallback
        // hiding every suggestion until Vocabulary is reopened. One key, so
        // a dictation ending (flag and ids change together) prunes once.
        .onChange(of: PruneTrigger(
            workInFlight: coordinator.mayStillWriteHistory,
            recordIDs: coordinator.history.records.map(\.id)
        )) { pruneRetiredRuleTargets() }
    }

    private struct PruneTrigger: Equatable {
        let workInFlight: Bool
        let recordIDs: [UUID]
    }

    /// Storage hygiene only: a retired target stays excluded until History
    /// no longer holds its text and no dictation is still writing. Assigns
    /// only on a change, so opening Settings does not rewrite the rules.
    /// Synchronous on the main actor: History and the in-flight flag are read
    /// and the result stored with no suspension in between.
    private func pruneRetiredRuleTargets() {
        let pruned = settings.replacementRules.pruningRetiredTargets(
            history: coordinator.history.records, workInFlight: coordinator.mayStillWriteHistory,
            index: retiredTargetIndex)
        if pruned != settings.replacementRules { settings.replacementRules = pruned }
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

    /// Terms worth offering: recurring in the speaker's own dictations, not
    /// already in the vocabulary, not previously turned down, and not written
    /// by a replacement rule (enabled, disabled or retired).
    private var termProposals: [DictionaryProposal] {
        let dismissed = Set(settings.dismissedTermProposals.map { $0.lowercased() })
        let proposals = DictionaryProposer.propose(
            from: coordinator.history.records,
            existing: settings.dictionary
        )
        .filter { !dismissed.contains($0.term.lowercased()) }
        // History holds post-rule text: a rule target is not a new term.
        return settings.replacementRules.excludingTargets(from: proposals)
    }

    private static func occurrenceSummary(_ count: Int) -> String {
        Localization.appPlural(
            "settings.vocabulary.dictationCount",
            fallback: count == 1 ? "in 1 dictation" : "in \(count) dictations",
            count: count
        )
    }

    private func accept(_ proposal: DictionaryProposal) {
        settings.dictionary.terms.append(proposal.term)
    }

    private func dismissProposal(_ proposal: DictionaryProposal) {
        settings.dismissedTermProposals.append(proposal.term)
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
