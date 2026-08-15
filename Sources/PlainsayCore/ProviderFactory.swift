import Foundation

/// Turns settings into the backends the pipeline actually runs.
///
/// One place decides which engine and which cleanup service you get, so the
/// coordinator never has to know a provider exists.
@MainActor
public enum ProviderFactory {
    public static func makeCleaner(_ settings: PlainsaySettings) -> any TextCleaning {
        guard settings.cleanupEnabled else { return NoCleanup() }

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
        onState: @escaping @Sendable (WhisperKitEngine.LoadState) -> Void
    ) -> any TranscriptionEngine {
        switch settings.transcriptionSource {
        case .onDevice:
            return WhisperKitEngine(
                model: settings.model,
                language: settings.language,
                onStateChange: onState
            )

        case .remote:
            let provider = settings.asrProvider
            let key = settings.apiKey(for: provider)
            guard !key.isEmpty else {
                // Falling back silently would be worse: dictation would keep
                // working while quietly ignoring the setting you chose.
                onState(.failed("No API key for \(provider.displayName)"))
                return WhisperKitEngine(
                    model: settings.model,
                    language: settings.language,
                    onStateChange: onState
                )
            }
            // Remote needs no loading, so report ready immediately or the
            // hotkey would refuse to record.
            onState(.ready)
            return RemoteWhisperEngine(
                baseURL: settings.resolvedASRBaseURL,
                apiKey: key,
                model: settings.resolvedASRModel,
                language: settings.language
            )
        }
    }
}
