import FluidAudio
import Foundation
@preconcurrency import WhisperKit

/// The only source file varied by the dictation quality loop.
enum DictationTuning {
    static let defaultModel: OnDeviceModel = .parakeetTDT06BV3

    static let whisperTemperature: Float = 0
    static let whisperFallbackIncrement: Float = 0.2
    static let whisperFallbackCount = 5
    static let whisperTopK = 5
    static let whisperCompressionThreshold: Float? = 2.4
    static let whisperLogProbThreshold: Float? = -1.0
    static let whisperFirstTokenThreshold: Float? = -1.5
    static let whisperNoSpeechThreshold: Float? = 0.9
    static let whisperAudiblePeak: Float = 0.02
    static let whisperChunkAfterSeconds: Double = 30
    static let whisperSuppressBlank = false
    static let whisperUseDictionaryPrompt = true
    static let whisperInitialPrompt: String? = nil
    static let whisperLeadingPadSeconds: Double = 0
    static let whisperTrailingPadSeconds: Double = 0

    static let parakeetMelChunkContext = false
    static let parakeetMaxSymbolsPerStep = 10
    static let parakeetMaxTokensPerChunk = 150
    static let parakeetConsecutiveBlankLimit = 5
    static let parakeetLeadingPadSeconds: Double = 0.32
    static let parakeetTrailingPadSeconds: Double = 0.04
    static let parakeetQuietPeakTarget: Float? = 0.3

    static let annotationPatterns = [#"\[[^\]]*\]"#, #"\([^\)]*\)"#, #"♪[^♪]*♪"#]
    static let nonSpeechMarkers: Set<String> = ["", ".", "-", "..."]

    static func usesPolishEnglishProfile(_ languages: [String]) -> Bool {
        languages.map(SupportedLanguage.primaryCode) == ["pl", "en"]
    }

    static func fallbackModel(for languages: [String]) -> OnDeviceModel {
        guard usesPolishEnglishProfile(languages), defaultModel.isSupportedOnCurrentHardware else {
            return .largeV3Turbo
        }
        return defaultModel
    }

    static func whisperOptions(sampleCount: Int, relaxed: Bool, forcedLanguage: String?,
                               englishOnly: Bool) -> DecodingOptions {
        let needsChunking = Double(sampleCount) / whisperSampleRate > whisperChunkAfterSeconds
        return DecodingOptions(
            task: .transcribe,
            language: englishOnly ? "en" : forcedLanguage,
            temperature: whisperTemperature,
            temperatureIncrementOnFallback: whisperFallbackIncrement,
            temperatureFallbackCount: whisperFallbackCount,
            topK: whisperTopK,
            usePrefillPrompt: true,
            detectLanguage: !englishOnly && forcedLanguage == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: whisperSuppressBlank,
            compressionRatioThreshold: relaxed ? nil : whisperCompressionThreshold,
            logProbThreshold: relaxed ? nil : whisperLogProbThreshold,
            firstTokenLogProbThreshold: whisperFirstTokenThreshold,
            noSpeechThreshold: relaxed ? nil : whisperNoSpeechThreshold,
            chunkingStrategy: needsChunking ? .vad : nil
        )
    }

    static func whisperAudio(_ samples: [Float]) -> [Float] {
        padded(samples, leading: whisperLeadingPadSeconds, trailing: whisperTrailingPadSeconds)
    }

    static func whisperPrompt(dictionaryPrompt: String?) -> String? {
        let parts = [whisperInitialPrompt, whisperUseDictionaryPrompt ? dictionaryPrompt : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func parakeetAudio(_ samples: [Float]) -> [Float] {
        var audio = samples
        if let target = parakeetQuietPeakTarget,
           let peak = samples.lazy.map({ abs($0) }).max(), peak > 0, peak < target {
            let gain = min(4, target / peak)
            audio = samples.map { $0 * gain }
        }
        return padded(audio, leading: parakeetLeadingPadSeconds, trailing: parakeetTrailingPadSeconds)
    }

    private static func padded(_ samples: [Float], leading: Double, trailing: Double) -> [Float] {
        guard leading > 0 || trailing > 0 else { return samples }
        let prefix = Int(leading * whisperSampleRate)
        let suffix = Int(trailing * whisperSampleRate)
        guard samples.count + prefix + suffix <= 30 * Int(whisperSampleRate) else { return samples }
        return [Float](repeating: 0, count: prefix) + samples + [Float](repeating: 0, count: suffix)
    }

    static func parakeetConfig(usesPolishEnglishProfile: Bool) -> ASRConfig {
        guard usesPolishEnglishProfile else { return ASRConfig(melChunkContext: false) }
        return ASRConfig(
            tdtConfig: TdtConfig(
                maxSymbolsPerStep: parakeetMaxSymbolsPerStep,
                maxTokensPerChunk: parakeetMaxTokensPerChunk,
                consecutiveBlankLimit: parakeetConsecutiveBlankLimit
            ),
            melChunkContext: parakeetMelChunkContext
        )
    }
}

/// Strips sound annotations and bare markers emitted for non-speech audio.
public func normalizeTranscript(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for pattern in DictationTuning.annotationPatterns {
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    text = text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return DictationTuning.nonSpeechMarkers.contains(text) ? "" : text
}
