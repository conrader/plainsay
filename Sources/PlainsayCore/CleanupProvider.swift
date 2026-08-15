import Foundation

/// Where the cleanup pass runs.
///
/// Everything except Gemini speaks the OpenAI chat-completions dialect, so one
/// client covers OpenRouter, OpenAI, Groq, Together, a local Ollama, or
/// anything else that implements `/v1/chat/completions`.
public enum CleanupProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case gemini
    case openRouter
    case openAI
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    /// Empty for `.custom`, where the user supplies it.
    public var defaultBaseURL: String {
        switch self {
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .gemini: "gemini-3.1-flash-lite"
        case .openRouter: "google/gemini-3.1-flash-lite"
        case .openAI: "gpt-5-mini"
        case .custom: ""
        }
    }

    /// Cheap, fast models worth suggesting. Cleanup is a rewriting task, so
    /// the smallest capable model is usually the right one — latency is felt
    /// on every single dictation.
    public var suggestedModels: [String] {
        switch self {
        case .gemini:
            ["gemini-3.1-flash-lite", "gemini-3.1-flash"]
        case .openRouter:
            [
                "google/gemini-3.1-flash-lite",
                "anthropic/claude-haiku-4.5",
                "openai/gpt-5-mini",
                "meta-llama/llama-3.3-70b-instruct",
            ]
        case .openAI:
            ["gpt-5-mini", "gpt-5-nano"]
        case .custom:
            []
        }
    }

    /// Keychain account, so switching provider does not lose the other keys.
    public var keychainAccount: String {
        switch self {
        case .gemini: "gemini-api-key"
        case .openRouter: "openrouter-api-key"
        case .openAI: "openai-api-key"
        case .custom: "custom-cleanup-api-key"
        }
    }

    public var signupURL: String? {
        switch self {
        case .gemini: "https://aistudio.google.com/apikey"
        case .openRouter: "https://openrouter.ai/keys"
        case .openAI: "https://platform.openai.com/api-keys"
        case .custom: nil
        }
    }

    /// Gemini has its own REST shape; everything else shares one client.
    public var usesOpenAIDialect: Bool { self != .gemini }
}
