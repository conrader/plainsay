import AppKit
import SwiftUI
import PlainsayCore

/// Sign-in and subscription for Plainsay Cloud.
///
/// Deliberately blunt about what changes when you turn this on: it is the one
/// setting in the app that sends your voice to someone else's computer, and
/// burying that in a footnote would be dishonest.
struct CloudSettingsView: View {
    let cloud: PlainsayCloudClient
    let onCredentialsChanged: () -> Void

    @State private var email = ""
    @State private var code = ""
    @State private var awaitingCode = false
    @State private var busy = false
    @State private var refreshing = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Group {
            if cloud.isSignedIn {
                signedIn
            } else {
                signIn
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isError ? Color.orange : Color.secondary)
            }
        }
        .task {
            guard cloud.isSignedIn else { return }
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Returning from Stripe is the common path here. Refreshing on
            // activation makes the newly active subscription appear without
            // asking the user to close the assistant or relaunch Plainsay.
            guard cloud.isSignedIn, !busy else { return }
            Task { await refresh() }
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signIn: some View {
        if awaitingCode {
            HStack {
                TextField("Six-digit code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await verify() } }
                Button("Sign in") { Task { await verify() } }
                    .disabled(code.count < 6 || busy)
            }
            Button("Use a different address") {
                awaitingCode = false
                code = ""
                message = nil
            }
            .buttonStyle(.borderless)
            .font(.callout)
        } else {
            HStack {
                TextField("Email", text: $email, prompt: Text("you@example.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await requestCode() } }
                Button("Send code") { Task { await requestCode() } }
                    .disabled(!email.contains("@") || busy)
            }
            Text("We email a six-digit code. No password to remember.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var signedIn: some View {
        if let account = cloud.account {
            LabeledContent("Account", value: account.email ?? "signed in")
            LabeledContent("Subscription") {
                if account.isActive {
                    Label(account.status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(account.status == "none" ? "not subscribed" : account.status,
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if account.isActive, account.limitSeconds > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(
                        value: Double(account.usedSeconds),
                        total: Double(account.limitSeconds)
                    )
                    Text("\(account.usedSeconds / 60) of \(account.limitSeconds / 60) minutes this month")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if account.isActive {
                    Button("Manage subscription") { Task { await openPortal() } }
                } else {
                    Button("Subscribe — about $3/month") { Task { await subscribe(annual: false) } }
                        .buttonStyle(.borderedProminent)
                    Button("About $30/year") { Task { await subscribe(annual: true) } }
                }
                Spacer()
                Button("Sign out", action: signOut)
                    .buttonStyle(.borderless)
                    .disabled(busy)
            }
        } else {
            HStack(spacing: 10) {
                if busy || message == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                Text(busy || message == nil ? "Checking your subscription…" : "Account status is unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { Task { await refresh() } }
                    .disabled(busy)
                Button("Sign out", action: signOut)
                    .buttonStyle(.borderless)
                    .disabled(busy)
            }
        }
    }

    // MARK: - Actions

    private func requestCode() async {
        await run("Code sent. Check your email.") {
            try await cloud.requestEmailCode(email)
            awaitingCode = true
        }
    }

    private func verify() async {
        await run(nil) {
            try await cloud.verifyEmailCode(email, code: code)
            awaitingCode = false
            code = ""
            await refresh()
        }
    }

    private func subscribe(annual: Bool) async {
        await run("Finish in your browser, then come back — this updates on its own.") {
            NSWorkspace.shared.open(try await cloud.checkoutURL(annual: annual))
        }
    }

    private func openPortal() async {
        await run(nil) { NSWorkspace.shared.open(try await cloud.portalURL()) }
    }

    private func signOut() {
        cloud.signOut()
        if ProviderFactory.cloudCredentials != nil || ProviderFactory.cloudSessionToken != nil {
            clearCloudState()
            onCredentialsChanged()
        }
        message = nil
    }

    /// Pulls account state and, if subscribed, the provider credentials.
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        await run(nil) {
            let account = try await cloud.refreshAccount()
            guard account.isActive else {
                if ProviderFactory.cloudCredentials != nil || ProviderFactory.cloudSessionToken != nil {
                    clearCloudState()
                    onCredentialsChanged()
                }
                return
            }
            let credentials = try await cloud.refreshCredentials()
            // The transcription engine authenticates with the session token
            // directly, so it has to be refreshed in the same pass as the
            // cleanup credentials — a stale token would leave transcription
            // failing silently while cleanup kept working.
            if ProviderFactory.cloudCredentials != credentials || ProviderFactory.cloudSessionToken != cloud.sessionToken {
                ProviderFactory.cloudCredentials = credentials
                ProviderFactory.cloudSessionToken = cloud.sessionToken
                onCredentialsChanged()
            }
        }
    }

    private func clearCloudState() {
        ProviderFactory.cloudCredentials = nil
        ProviderFactory.cloudSessionToken = nil
    }

    private func run(_ success: String?, _ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            isError = false
            message = success
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}
