import SwiftUI
import PlainsayCore

struct PermissionRow: View {
    let permission: Permission
    let isGranted: Bool
    let onChange: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isGranted, let afterGranting = permission.afterGranting {
                    Label(afterGranting, systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer()
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                // macOS asks once and never again. Once it has, this button
                // can only open System Settings, and calling it "Grant" makes
                // a button that visibly does nothing look broken.
                Button(
                    permission.canStillPrompt
                        ? Localization.appString("permission.action.grant", fallback: "Grant")
                        : Localization.appString("permission.action.openSettings", fallback: "Open Settings…")
                ) {
                    Task {
                        await permission.request()
                        onChange()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
