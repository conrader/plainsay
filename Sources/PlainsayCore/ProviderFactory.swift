import Foundation

/// Turns settings into the backends the pipeline actually runs.
///
/// One place decides which engine and which cleanup service you get, so the
/// coordinator never has to know a provider exists.
@MainActor
public enum ProviderFactory {
    /// Credentials for the current Plainsay Cloud session, if any.
    ///
    /// Held here rather than in settings because they must never be persisted:
    /// settings write through to `UserDefaults`, and the deAPI key in here is
    /// shared between every subscriber.
    public static var cloudCredentials: CloudCredentials?
    /// Session token for `CloudTranscriptionEngine`. Set alongside
    /// `cloudCredentials` — kept separate because it authenticates a proxy
    /// call to our own server, not a direct call to a provider.
    public static var cloudSessionToken: String?

    public static func makeCleaner(_ settings: PlainsaySettings) -> any TextCleaning {
        guard settings.cleanupEnabled else { return NoCleanup() }

        // Polishing via Plainsay itself is independent of which transcription
        // source is active — someone dictating entirely on-device can still
        // pick this as their editing provider. No stored key to check, only
        // whether a subscription actually minted one into memory.
        if settings.cleanupProvider == .plainsay {
            guard let cloud = cloudCredentials else { return NoCleanup() }
            return OpenAICompatibleCleanupService(
                baseURL: cloud.cleanup.baseURL,
                apiKey: cloud.cleanup.key,
                model: cloud.cleanup.model
            )
        }

        let provider = settings.cleanupProvider
        let key = settings.apiKey(for: provider)
        // No key means no cleanup, rather than a failing call on every
        // dictation: the raw transcript is a fine outcome, an error is not.
        guard !key.isEmpty else { return NoCleanup() }

        if provider.usesOpenAIDialect {
            return OpenAICompatibleCleanupService(
                baseURL: settings.resolvedCleanupBaseURL,
                apiKey: key,
                model: settings.resolvedCleanupModel
            )
        }

        if provider == .anthropic {
            return AnthropicCleanupService(
                apiKey: key,
                model: settings.resolvedCleanupModel
            )
        }

        return GeminiCleanupService(
            apiKey: key,
            model: settings.resolvedCleanupModel
        )
    }

    public static func makeEngine(
        _ settings: PlainsaySettings,
        onState: @escaping @Sendable (SpeechModelLoadState) -> Void
    ) -> any TranscriptionEngine {
        switch settings.transcriptionSource {
        case .onDevice:
            return makeOnDeviceEngine(settings, onState: onState)

        case .cloud:
            guard cloudCredentials != nil, let token = cloudSessionToken else {
                // Signed out, unsubscribed, or the key fetch failed. Say so
                // rather than silently transcribing on-device: the user picked
                // Cloud, and quietly doing something else hides a billing
                // problem behind working dictation.
                let message = Localization.coreString(
                    "cloud.signInRequired", fallback: "Sign in to Plainsay Cloud in Settings › Speech."
                )
                onState(.failed(message))
                return UnavailableTranscriptionEngine(message: message)
            }
            onState(.ready)
            // Proxied through Plainsay's own server, not deAPI directly — see
            // CloudTranscriptionEngine for why.
            return CloudTranscriptionEngine(
                baseURL: PlainsayCloudClient.defaultBaseURL,
                sessionToken: token,
                language: settings.primaryLanguage
            )

        case .remote:
            let provider = settings.asrProvider
            let key = settings.apiKey(for: provider)
            guard !key.isEmpty else {
                // Falling back silently would be worse: dictation would keep
                // working while quietly ignoring the setting you chose.
                let message = Localization.coreFormat(
                    "engine.noApiKeyFor", fallback: "No API key for %@", provider.displayName
                )
                onState(.failed(message))
                return UnavailableTranscriptionEngine(message: message)
            }
            // Remote needs no loading, so report ready immediately or the
            // hotkey would refuse to record.
            onState(.ready)
            return RemoteWhisperEngine(
                baseURL: settings.resolvedASRBaseURL,
                apiKey: key,
                model: settings.resolvedASRModel,
                language: settings.primaryLanguage,
                uploadFormat: provider.uploadFormat
            )
        }
    }

    private static func makeOnDeviceEngine(
        _ settings: PlainsaySettings,
        onState: @escaping @Sendable (SpeechModelLoadState) -> Void
    ) -> any TranscriptionEngine {
        switch settings.model {
        case .parakeetTDT06BV3:
            ParakeetEngine(
                language: settings.primaryLanguage,
                onStateChange: onState
            )
        default:
            WhisperKitEngine(
                model: settings.model,
                spokenLanguages: settings.spokenLanguages,
                onStateChange: onState
            )
        }
    }
}

private struct UnavailableTranscriptionEngine: TranscriptionEngine {
    let message: String

    func prepare() async throws {
        throw TranscriptionError.failed(message)
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> String {
        throw TranscriptionError.failed(message)
    }
}
