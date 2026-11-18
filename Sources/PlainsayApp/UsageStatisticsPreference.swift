import SwiftUI
import PlainsayCore

struct UsageStatisticsPreference: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(Localization.appString(
                "usageStatistics.toggle", fallback: "Share anonymous usage statistics"
            ), isOn: $isOn)
            Text(Localization.appString(
                "usageStatistics.detail",
                fallback: """
                    Optional. Help improve Plainsay by sharing daily usage ranges, app and macOS                     versions, speech mode, language hints, and failure counts. Dictation content                     and account details are never included. Turn this off in Settings › General                     to stop sharing and delete pending statistics.
                    """
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Link(
                Localization.appString("usageStatistics.privacyLink", fallback: "Usage statistics privacy details"),
                destination: URL(string: "https://plainsay.app/privacy/#usage-statistics")!
            )
            .font(.callout)
        }
    }
}
