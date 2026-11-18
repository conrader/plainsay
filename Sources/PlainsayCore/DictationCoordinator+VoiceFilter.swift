import Foundation

extension DictationCoordinator {
    /// Filters `samples` down to the enrolled voice when the feature is on
    /// and actually ready. Fails open on any problem — an unloaded filter, a
    /// missing enrollment, or a diarization error all just mean "transcribe
    /// what was recorded," the same as if filtering were off.
    func applyVoiceFilterIfNeeded(_ samples: [Float]) async -> [Float] {
        guard settings.voiceFilterEnabled,
              let embedding = settings.voiceEmbedding,
              let voiceFilter,
              await voiceFilter.isReady
        else { return samples }

        do {
            let outcome = try await voiceFilter.filter(samples: samples, matching: embedding)
            // Without this a filtered-out tail is indistinguishable from one
            // the engine never transcribed, and without the ranges a lost
            // ending cannot be told from a second voice mid-dictation.
            Log.pipeline.info("""
                voice filter kept \(Double(outcome.samples.count) / whisperSampleRate, format: .fixed(precision: 2), privacy: .public)s \
                of \(Double(samples.count) / whisperSampleRate, format: .fixed(precision: 2), privacy: .public)s, \
                removed \(VoiceFilterOutcome.describe(outcome.removed), privacy: .public)
                """)
            VoiceFilterDebugAudio.saveIfEnabled(captured: samples, filtered: outcome.samples, policy: sessionPolicy)
            return outcome.samples
        } catch {
            Log.pipeline.error("voice filter failed, using unfiltered audio: \(error.localizedDescription, privacy: .public)")
            return samples
        }
    }
}
