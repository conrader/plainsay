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

    @Test("A 402 is reported as a subscription problem, not a generic failure")
    func surfacesMissingSubscription() async {
        MockURLProtocol.respond(host: cloudHost, status: 402, json: #"{"error":"No active subscription","status":"canceled"}"#)

        let client = makeClient()
        await #expect(throws: CloudError.noSubscription(status: "canceled")) {
            try await client.refreshAccount()
        }
    }

    @Test("Calls that need a token refuse before hitting the network")
    func refusesWithoutToken() async {
        let client = makeClient(token: nil)
        await #expect(throws: CloudError.notSignedIn) {
            try await client.refreshAccount()
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

    @Test("Signing out revokes the server session before dropping the token")
    func signOutClears() async throws {
        MockURLProtocol.respond(host: cloudHost, json: #"{"status":"active","usage":{"usedSeconds":0,"limitSeconds":1}}"#)
        MockURLProtocol.reset(host: cloudHost)

        let client = makeClient()
        _ = try await client.refreshAccount()
        #expect(client.account != nil)

        try await client.signOut()

        #expect(client.account == nil)
        #expect(!client.isSignedIn)
        let request = try #require(MockURLProtocol.lastRequest(for: cloudHost))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/auth/signout")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer psk_test")
    }

    @Test("A failed revocation keeps the token so sign-out can be retried")
    func failedSignOutCanRetry() async {
        MockURLProtocol.respond(host: cloudHost, status: 503, json: #"{"error":"temporarily unavailable"}"#)

        let client = makeClient()
        await #expect(throws: CloudError.http(status: 503, message: "temporarily unavailable")) {
            try await client.signOut()
        }

        #expect(client.isSignedIn)
    }

    @Test("An already-invalid server token is cleared locally")
    func invalidTokenClears() async throws {
        MockURLProtocol.respond(host: cloudHost, status: 401, json: #"{"error":"Unknown or revoked token"}"#)

        let client = makeClient()
        try await client.signOut()

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

    @Test("Choosing Cloud without a session token does not silently fall back")
    func cloudWithoutCredentialsReportsFailure() async {
        let settings = freshSettings()
        settings.transcriptionSource = .cloud
        settings.model = .parakeetTDT06BV3
        ProviderFactory.cloudSessionToken = nil

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

    @Test("The Cloud session token is never written to settings")
    func credentialsAreNotPersisted() {
        let suite = "plainsay.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = PlainsaySettings(defaults: defaults)
        settings.transcriptionSource = .cloud

        ProviderFactory.cloudSessionToken = "psk_secret"
        defer { ProviderFactory.cloudSessionToken = nil }

        // The token that authenticates transcription and cleanup must not
        // survive a restart on disk.
        let dump = defaults.dictionaryRepresentation().description
        #expect(!dump.contains("psk_secret"))
    }
}

let cloudTranscribeHost = "cloud-transcribe.plainsay.test"

@Suite("Cloud transcription engine", .serialized)
struct CloudTranscriptionEngineTests {
    private func tone(seconds: Double = 1.0) -> [Float] {
        let count = Int(seconds * whisperSampleRate)
        return (0..<count).map { i in sin(2 * .pi * 440 * Float(i) / Float(whisperSampleRate)) * 0.3 }
    }

    private func makeEngine(language: String? = nil) -> CloudTranscriptionEngine {
        CloudTranscriptionEngine(
            baseURL: "https://\(cloudTranscribeHost)",
            sessionToken: "psk_test",
            language: language,
            session: MockURLProtocol.session()
        )
    }

    @Test("Posts AAC audio with the session token and the client's own duration")
    func requestShape() async throws {
        MockURLProtocol.respond(host: cloudTranscribeHost, json: #"{"text":"hello there"}"#)
        MockURLProtocol.reset(host: cloudTranscribeHost)

        _ = try await makeEngine(language: "pl").transcribe(samples: tone(seconds: 2), prompt: "Plainsay")

        let request = try #require(MockURLProtocol.lastRequest(for: cloudTranscribeHost))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer psk_test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == AudioUploadFormat.m4a.mimeType)

        let url = try #require(request.url)
        #expect(url.path == "/v1/transcribe")
        #expect(url.query == nil)

        let encoded = try #require(request.value(forHTTPHeaderField: "X-Plainsay-Metadata"))
        var base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let metadataData = try #require(Data(base64Encoded: base64))
        let metadata = try #require(try JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        #expect(metadata["language"] as? String == "pl")
        #expect(metadata["prompt"] as? String == "Plainsay")
        // Duration comes from the sample count the client actually recorded,
        // not from re-parsing the encoded upload — the server trusts this
        // value for both the fair-use cap and its own usage accounting.
        let seconds = try #require(metadata["durationSeconds"] as? Double)
        #expect(abs(seconds - 2.0) < 0.01)
    }

    @Test("A 402 reports the subscription as the problem")
    func mapsSubscriptionRequired() async {
        MockURLProtocol.respond(host: cloudTranscribeHost, status: 402, json: #"{"error":"No active subscription"}"#)

        await #expect(throws: TranscriptionError.self) {
            try await self.makeEngine().transcribe(samples: tone(), prompt: nil)
        }
    }

    @Test("A 429 reports the fair-use limit as the problem")
    func mapsFairUseLimit() async {
        MockURLProtocol.respond(host: cloudTranscribeHost, status: 429, json: #"{"error":"limit reached"}"#)

        await #expect(throws: TranscriptionError.self) {
            try await self.makeEngine().transcribe(samples: tone(), prompt: nil)
        }
    }

    @Test("Empty audio never reaches the network")
    func emptyAudioSkipsUpload() async throws {
        MockURLProtocol.reset(host: cloudTranscribeHost)
        let text = try await makeEngine().transcribe(samples: [], prompt: nil)
        #expect(text.isEmpty)
        #expect(MockURLProtocol.lastRequest(for: cloudTranscribeHost) == nil)
    }
}

let cloudCleanupHost = "cloud-cleanup.plainsay.test"

@Suite("Cloud cleanup service", .serialized)
struct CloudCleanupServiceTests {
    private func makeService() -> CloudCleanupService {
        CloudCleanupService(
            baseURL: "https://\(cloudCleanupHost)",
            sessionToken: "psk_test",
            session: MockURLProtocol.session()
        )
    }

    @Test("Posts the transcript and vocabulary hint with the session token, not a provider key")
    func requestShape() async throws {
        MockURLProtocol.respond(host: cloudCleanupHost, json: #"{"text":"I'll be there Tuesday."}"#)
        MockURLProtocol.reset(host: cloudCleanupHost)

        let result = try await makeService()
            .clean("um i'll uh be there tuesday", dictionary: TermDictionary(terms: ["Plainsay"]), style: .plain)

        #expect(result == "I'll be there Tuesday.")

        let request = try #require(MockURLProtocol.lastRequest(for: cloudCleanupHost))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer psk_test")
        #expect(request.url?.path == "/v1/cleanup")

        let body = try #require(MockURLProtocol.lastBody(for: cloudCleanupHost))
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["transcript"] as? String == "um i'll uh be there tuesday")
        #expect((root["terms"] as? String)?.contains("Plainsay") == true)
        // The system prompt lives server-side now — the request carries no
        // API key and no prompt text, only the transcript and a vocabulary hint.
        #expect(root["key"] == nil)
    }

    @Test("A 402 reports the subscription as the problem")
    func mapsSubscriptionRequired() async {
        MockURLProtocol.respond(host: cloudCleanupHost, status: 402, json: #"{"error":"No active subscription"}"#)

        await #expect(throws: CleanupError.self) {
            try await self.makeService().clean("hello", dictionary: TermDictionary(), style: .plain)
        }
    }

    @Test("Empty transcripts never reach the network")
    func emptyTranscriptSkipsUpload() async throws {
        MockURLProtocol.reset(host: cloudCleanupHost)
        let text = try await makeService().clean("   ", dictionary: TermDictionary(), style: .plain)
        #expect(text.isEmpty)
        #expect(MockURLProtocol.lastRequest(for: cloudCleanupHost) == nil)
    }
}
