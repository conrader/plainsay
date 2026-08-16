import Foundation

/// Where the cleanup pass runs.
///
/// OpenRouter, OpenAI, and custom speak the OpenAI chat-completions dialect,
/// so one client covers OpenRouter, OpenAI, Groq, Together, a local Ollama, or
/// anything else that implements `/v1/chat/completions`. Gemini and Anthropic
/// each have their own REST shape and get their own client.
public enum CleanupProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case gemini
    case anthropic
    case openRouter
    case openAI
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: Localization.coreString("cleanupProvider.displayName.gemini", fallback: "Google Gemini")
        case .anthropic:
            Localization.coreString("cleanupProvider.displayName.claude", fallback: "Anthropic Claude")
        case .openRouter: Localization.coreString("cleanupProvider.displayName.openrouter", fallback: "OpenRouter")
        case .openAI: Localization.coreString("cleanupProvider.displayName.openai", fallback: "OpenAI")
        case .custom:
            Localization.coreString(
                "cleanupProvider.displayName.custom", fallback: "Custom (OpenAI-compatible)"
            )
        }
    }

    /// Empty for `.custom`, where the user supplies it.
    public var defaultBaseURL: String {
        switch self {
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .anthropic: "https://api.anthropic.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .gemini: "gemini-3.1-flash-lite"
        case .anthropic: AnthropicCleanupService.defaultModel
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
        case .anthropic:
            ["claude-haiku-4-5", "claude-haiku-4-5-20251001"]
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
        case .anthropic: "anthropic-api-key"
        case .openRouter: "openrouter-api-key"
        case .openAI: "openai-api-key"
        case .custom: "custom-cleanup-api-key"
        }
    }

    public var signupURL: String? {
        switch self {
        case .gemini: "https://aistudio.google.com/apikey"
        case .anthropic: "https://console.anthropic.com/settings/keys"
        case .openRouter: "https://openrouter.ai/keys"
        case .openAI: "https://platform.openai.com/api-keys"
        case .custom: nil
        }
    }

    /// Gemini and Anthropic each have their own REST shape; everything else
    /// shares one OpenAI-dialect client.
    public var usesOpenAIDialect: Bool {
        self != .gemini && self != .anthropic
    }
}
