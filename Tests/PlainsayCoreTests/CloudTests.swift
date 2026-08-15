import Foundation
import Testing
@testable import PlainsayCore

let cloudHost = "cloud.plainsay.test"

private final class MemoryTokenStore: CloudTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(token: String? = nil) { stored = token }

    var token: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite("Plainsay Cloud client", .serialized)
@MainActor
struct PlainsayCloudTests {
    private func makeClient(token: String? = "psk_test") -> PlainsayCloudClient {
        PlainsayCloudClient(
            baseURL: "https://\(cloudHost)",
            tokenStore: MemoryTokenStore(token: token),
            session: MockURLProtocol.session()
        )
    }

    @Test("Credentials arrive for both stages and are held in memory")
    func fetchesCredentials() async throws {
        MockURLProtocol.respond(host: cloudHost, json: """
        {"transcription":{"baseURL":"https://oai.deapi.ai/v1","model":"WhisperLargeV3","key":"dpn-sk-shared"},
         "cleanup":{"baseURL":"https://openrouter.ai/api/v1","model":"google/gemini-3.1-flash-lite","key":"sk-or-minted"}}
        """)

        let client = makeClient()
        let credentials = try await client.refreshCredentials()

        #expect(credentials.transcription.key == "dpn-sk-shared")
        #expect(credentials.cleanup.key == "sk-or-minted")
        #expect(credentials.cleanup.model == "google/gemini-3.1-flash-lite")
        #expect(client.credentials == credentials)
    }

    @Test("A 402 is reported as a subscription problem, not a generic failure")
    func surfacesMissingSubscription() async {
        MockURLProtocol.respond(host: cloudHost, status: 402, json: #"{"error":"No active subscription","status":"canceled"}"#)

        let client = makeClient()
        await #expect(throws: CloudError.noSubscription(status: "canceled")) {
            try await client.refreshCredentials()
        }
    }

    @Test("Calls that need a token refuse before hitting the network")
    func refusesWithoutToken() async {
        let client = makeClient(token: nil)
        await #expect(throws: CloudError.notSignedIn) {
            try await client.refreshCredentials()
        }
    }

    @Test("Account usage is parsed for the settings screen")
    func parsesAccount() async throws {
        MockURLProtocol.respond(host: cloudHost, json: """
        {"email":"a@b.co","status":"active","currentPeriodEnd":1790000000,
         "usage":{"usedSeconds":1234,"limitSeconds":54000}}
        """)

        let account = try await makeClient().refreshAccount()

        #expect(account.status == "active")
        #expect(account.isActive)
        #expect(account.usedSeconds == 1234)
    }

    @Test("past_due still counts as active so a retry does not lock you out mid-sentence")
    func pastDueStaysUsable() async throws {
        MockURLProtocol.respond(host: cloudHost, json: #"{"status":"past_due","usage":{"usedSeconds":0,"limitSeconds":1}}"#)
        #expect(try await makeClient().refreshAccount().isActive)
    }

    @Test("Signing out drops the token and everything spendable")
    func signOutClears() async throws {
        MockURLProtocol.respond(host: cloudHost, json: """
        {"transcription":{"baseURL":"u","model":"m","key":"k"},"cleanup":{"baseURL":"u","model":"m","key":"k"}}
        """)

        let client = makeClient()
        _ = try await client.refreshCredentials()
        #expect(client.credentials != nil)

        client.signOut()

        #expect(client.credentials == nil)
        #expect(!client.isSignedIn)
    }
}

/// Collects a state callback that the factory hands out as `@Sendable`.
private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SpeechModelLoadState?
    var value: SpeechModelLoadState? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite("On-device stays the default")
@MainActor
struct OnDeviceDefaultTests {
    private func freshSettings() -> PlainsaySettings {
        PlainsaySettings(defaults: UserDefaults(suiteName: "plainsay.tests.\(UUID().uuidString)")!)
    }

    @Test("A fresh install transcribes on this Mac")
    func defaultsToOnDevice() {
        // The product's claim is that audio does not leave the machine. Any
        // change that flips this default breaks the promise, not just a
        // preference, so it is asserted rather than assumed.
        #expect(freshSettings().transcriptionSource == .onDevice)
    }

    @Test("Only the on-device source keeps audio local")
    func sourcesDeclareWhetherAudioLeaves() {
        #expect(!TranscriptionSource.onDevice.leavesTheMachine)
        #expect(TranscriptionSource.remote.leavesTheMachine)
        #expect(TranscriptionSource.cloud.leavesTheMachine)
    }

    @Test("Choosing Cloud without credentials does not silently fall back")
    func cloudWithoutCredentialsReportsFailure() async {
        let settings = freshSettings()
        settings.transcriptionSource = .cloud
        settings.model = .parakeetTDT06BV3
        ProviderFactory.cloudCredentials = nil

        let box = StateBox()
        let engine = ProviderFactory.makeEngine(settings) { box.value = $0 }
        let reported = box.value

        // Working dictation that quietly ignores the paid setting would hide a
        // billing problem behind an apparently fine app.
        if case .failed = reported {} else {
            Issue.record("expected a failure state, got \(String(describing: reported))")
        }

        do {
            try await engine.prepare()
            Issue.record("missing Cloud credentials unexpectedly prepared a local engine")
        } catch {
            #expect(error.localizedDescription.contains("Sign in to Plainsay Cloud"))
        }
    }

    @Test("Cloud credentials are never written to settings")
    func credentialsAreNotPersisted() {
        let suite = "plainsay.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = PlainsaySettings(defaults: defaults)
        settings.transcriptionSource = .cloud

        ProviderFactory.cloudCredentials = CloudCredentials(
            transcription: .init(baseURL: "u", model: "m", key: "dpn-sk-secret"),
            cleanup: .init(baseURL: "u", model: "m", key: "sk-or-secret")
        )
        defer { ProviderFactory.cloudCredentials = nil }

        // The shared deAPI key must not survive a restart on disk.
        let dump = defaults.dictionaryRepresentation().description
        #expect(!dump.contains("dpn-sk-secret"))
        #expect(!dump.contains("sk-or-secret"))
    }
}
