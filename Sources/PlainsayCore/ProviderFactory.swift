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

    public static func makeCleaner(_ settings: PlainsaySettings) -> any TextCleaning {
        guard settings.cleanupEnabled else { return NoCleanup() }

        // A Cloud subscription supplies its own minted cleanup key, so it wins
        // over whatever provider is configured for bring-your-own-key use.
        if settings.transcriptionSource == .cloud, let cloud = cloudCredentials {
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
            guard let cloud = cloudCredentials else {
                // Signed out, unsubscribed, or the key fetch failed. Say so
                // rather than silently transcribing on-device: the user picked
                // Cloud, and quietly doing something else hides a billing
                // problem behind working dictation.
                let message = "Sign in to Plainsay Cloud in Settings › Speech"
                onState(.failed(message))
                return UnavailableTranscriptionEngine(message: message)
            }
            onState(.ready)
            return RemoteWhisperEngine(
                baseURL: cloud.transcription.baseURL,
                apiKey: cloud.transcription.key,
                model: cloud.transcription.model,
                language: settings.language,
                // The hosted plan transcribes through deAPI, which needs m4a.
                uploadFormat: .m4a
            )

        case .remote:
            let provider = settings.asrProvider
            let key = settings.apiKey(for: provider)
            guard !key.isEmpty else {
                // Falling back silently would be worse: dictation would keep
                // working while quietly ignoring the setting you chose.
                let message = "No API key for \(provider.displayName)"
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
                language: settings.language,
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
                language: settings.language,
                onStateChange: onState
            )
        default:
            WhisperKitEngine(
                model: settings.model,
                language: settings.language,
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
