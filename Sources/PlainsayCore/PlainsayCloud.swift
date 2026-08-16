import Foundation
import Observation

/// Credentials handed out by the Plainsay service for the current session.
///
/// Held in memory and nowhere else. Not the Keychain, not `UserDefaults`, not
/// a cache file — they are re-fetched on every launch.
///
/// Transcription is deliberately absent here. deAPI does not yet support
/// minting a key per subscriber the way OpenRouter does, so there is no safe
/// individual credential to hand out — only one key shared by everyone. Hand
/// that out and its life on any one Mac becomes the size of the leak surface.
/// Transcription is proxied through `CloudTranscriptionEngine` instead, using
/// the session token below; the deAPI key never reaches the client.
public struct CloudCredentials: Sendable, Equatable {
    public struct Endpoint: Sendable, Equatable {
        public let baseURL: String
        public let model: String
        public let key: String
    }

    public let cleanup: Endpoint
}

public enum CloudError: LocalizedError, Equatable {
    case notSignedIn
    case noSubscription(status: String)
    case http(status: Int, message: String)
    case malformedResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Sign in to Plainsay Cloud in Settings › Speech."
        case .noSubscription(let status):
            status == "none"
                ? "Plainsay Cloud needs an active subscription."
                : "Your Plainsay Cloud subscription is \(status)."
        case .http(let status, let message):
            message.isEmpty ? "Plainsay Cloud returned HTTP \(status)." : message
        case .malformedResponse:
            "Plainsay Cloud sent something unexpected."
        case .network(let message):
            "Could not reach Plainsay Cloud: \(message)"
        }
    }
}

/// Talks to the Plainsay subscription service.
///
/// The session token is the only thing that persists; everything spendable is
/// fetched fresh and kept in memory.
@MainActor
@Observable
public final class PlainsayCloudClient {
    public private(set) var credentials: CloudCredentials?
    public private(set) var account: Account?

    public struct Account: Sendable, Equatable {
        public let email: String?
        public let status: String
        public let usedSeconds: Int
        public let limitSeconds: Int

        public var isActive: Bool {
            status == "active" || status == "trialing" || status == "past_due"
        }
    }

    /// Single source of truth for the service host, so `ProviderFactory`
    /// doesn't carry a second hardcoded copy that could drift from this one.
    public nonisolated static let defaultBaseURL = "https://api.plainsay.app"

    /// Exposed so `CloudTranscriptionEngine` talks to the same host this
    /// client was configured for, rather than a second hardcoded copy of it.
    public let baseURL: String
    private let session: URLSession
    private let tokenStore: CloudTokenStoring

    public init(
        baseURL: String = PlainsayCloudClient.defaultBaseURL,
        tokenStore: CloudTokenStoring = KeychainCloudTokenStore(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.tokenStore = tokenStore
        self.session = session
    }

    public var isSignedIn: Bool { tokenStore.token?.isEmpty == false }

    /// The bearer token `CloudTranscriptionEngine` authenticates with. Only
    /// identifies the account and is revocable server-side — unlike a
    /// provider key, it cannot itself be spent against anyone else's bill.
    public var sessionToken: String? { tokenStore.token }

    public func signOut() {
        tokenStore.token = nil
        credentials = nil
        account = nil
    }

    // MARK: - Sign in

    public func requestEmailCode(_ email: String) async throws {
        _ = try await post("/v1/auth/email", body: ["email": email], authorized: false)
    }

    public func verifyEmailCode(_ email: String, code: String) async throws {
        let json = try await post("/v1/auth/email/verify", body: ["email": email, "code": code], authorized: false)
        try storeToken(from: json)
    }

    public func signInWithApple(identityToken: String) async throws {
        let json = try await post("/v1/auth/apple", body: ["identityToken": identityToken], authorized: false)
        try storeToken(from: json)
    }

    private func storeToken(from json: [String: Any]) throws {
        guard let token = json["token"] as? String, !token.isEmpty else { throw CloudError.malformedResponse }
        tokenStore.token = token
    }

    // MARK: - Account and credentials

    @discardableResult
    public func refreshAccount() async throws -> Account {
        let json = try await get("/v1/me")
        let usage = json["usage"] as? [String: Any]
        let account = Account(
            email: json["email"] as? String,
            status: json["status"] as? String ?? "none",
            usedSeconds: usage?["usedSeconds"] as? Int ?? 0,
            limitSeconds: usage?["limitSeconds"] as? Int ?? 0
        )
        self.account = account
        return account
    }

    /// Fetches the provider credentials for this session.
    @discardableResult
    public func refreshCredentials() async throws -> CloudCredentials {
        let json = try await get("/v1/keys")

        func endpoint(_ key: String) throws -> CloudCredentials.Endpoint {
            guard
                let raw = json[key] as? [String: Any],
                let baseURL = raw["baseURL"] as? String,
                let model = raw["model"] as? String,
                let apiKey = raw["key"] as? String
            else { throw CloudError.malformedResponse }
            return .init(baseURL: baseURL, model: model, key: apiKey)
        }

        let credentials = CloudCredentials(cleanup: try endpoint("cleanup"))
        self.credentials = credentials
        return credentials
    }

    public func checkoutURL(annual: Bool) async throws -> URL {
        let json = try await post("/v1/billing/checkout", body: ["interval": annual ? "annual" : "monthly"], authorized: true)
        guard let string = json["url"] as? String, let url = URL(string: string) else {
            throw CloudError.malformedResponse
        }
        return url
    }

    public func portalURL() async throws -> URL {
        let json = try await post("/v1/billing/portal", body: [:], authorized: true)
        guard let string = json["url"] as? String, let url = URL(string: string) else {
            throw CloudError.malformedResponse
        }
        return url
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> [String: Any] {
        guard let token = tokenStore.token else { throw CloudError.notSignedIn }
        guard let url = URL(string: baseURL + path) else { throw CloudError.malformedResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return try await send(request)
    }

    private func post(_ path: String, body: [String: Any], authorized: Bool) async throws -> [String: Any] {
        guard let url = URL(string: baseURL + path) else { throw CloudError.malformedResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if authorized {
            guard let token = tokenStore.token else { throw CloudError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw CloudError.malformedResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard (200..<300).contains(http.statusCode) else {
            // 402 is the one the UI acts on: it means "signed in, not paying".
            if http.statusCode == 402 {
                throw CloudError.noSubscription(status: json["status"] as? String ?? "none")
            }
            throw CloudError.http(status: http.statusCode, message: json["error"] as? String ?? "")
        }
        return json
    }
}

// MARK: - Token storage

public protocol CloudTokenStoring: Sendable {
    var token: String? { get nonmutating set }
}

/// The session token lives in the Keychain; the provider keys never do.
///
/// The distinction is deliberate. This token only identifies the account and
/// can be revoked server-side, so persisting it is what stops the app asking
/// you to sign in every launch. The provider keys can spend money, so they get
/// no such convenience.
public struct KeychainCloudTokenStore: CloudTokenStoring {
    private static let account = "cloud-session-token"

    public init() {}

    public var token: String? {
        get { Keychain.get(account: Self.account) }
        nonmutating set { Keychain.set(newValue ?? "", account: Self.account) }
    }
}
