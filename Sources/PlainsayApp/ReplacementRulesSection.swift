import SwiftUI
import PlainsayCore

// MARK: - Speech: Replacement rules

/// Settings → Speech → Replacement rules, directly under Vocabulary
/// (SPEC.fixed.md §2.5, minimal v1): the master switch, then every rule
/// newest first with an enabled toggle, its source and a delete button.
/// Rules are created from the correction window; manual Add, inline edit and
/// the filter field are follow-up work.
struct ReplacementRulesSection: View {
    @Bindable var settings: PlainsaySettings

    var body: some View {
        Section(RuleText.settingsTitle) {
            Toggle(RuleText.settingsToggle, isOn: $settings.replacementRules.isEnabled)
            Text(RuleText.settingsExplanation + " " + RuleText.settingsTranslation)
                .font(.callout)
                .foregroundStyle(.secondary)

            if settings.replacementRules.rules.isEmpty {
                Text(RuleText.settingsEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.replacementRules.newestFirst) { rule in
                    row(rule)
                }
            }
        }
    }

    private func row(_ rule: ReplacementRule) -> some View {
        HStack {
            Toggle(isOn: enabled(rule)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(rule.from) → \(rule.to)")
                    Text(rule.source == .correction ? RuleText.sourceCorrection : RuleText.sourceManual)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(RuleText.enable(from: rule.from, to: rule.to))
            Spacer()
            Button {
                settings.replacementRules.remove(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(RuleText.delete(from: rule.from, to: rule.to))
            .help(RuleText.delete(from: rule.from, to: rule.to))
        }
        .opacity(settings.replacementRules.isEnabled ? 1 : 0.5)
    }

    private func enabled(_ rule: ReplacementRule) -> Binding<Bool> {
        Binding(
            get: { settings.replacementRules.rules.first { $0.id == rule.id }?.isEnabled ?? false },
            set: { settings.replacementRules.setEnabled($0, id: rule.id) }
        )
    }
}
