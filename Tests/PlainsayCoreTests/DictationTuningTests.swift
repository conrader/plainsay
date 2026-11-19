import FluidAudio
import Foundation
import Testing
@testable import PlainsayCore

/// Locks in the scope of the dictation-quality winner: input gain and
/// padding apply to the Polish-primary/English-secondary profile only, never
/// clip, and every other profile keeps the pre-tuning decoder configuration.
@Suite("Dictation tuning scope")
struct DictationTuningTests {
    private let rate = Int(whisperSampleRate)
    private var prefix: Int { Int(DictationTuning.parakeetLeadingPadSeconds * whisperSampleRate) }
    private var suffix: Int { Int(DictationTuning.parakeetTrailingPadSeconds * whisperSampleRate) }

    private func peak(_ samples: [Float]) -> Float {
        samples.map(abs).max() ?? 0
    }

    @Test("Only the exact Polish-primary, English-secondary list is in scope")
    func profileScope() {
        #expect(DictationTuning.usesPolishEnglishProfile(["pl", "en"]))
        #expect(DictationTuning.usesPolishEnglishProfile(["pl-PL", "en_US"]))
        #expect(!DictationTuning.usesPolishEnglishProfile(["en", "pl"]))
        #expect(!DictationTuning.usesPolishEnglishProfile(["pl"]))
        #expect(!DictationTuning.usesPolishEnglishProfile(["pl", "en", "de"]))
        #expect(!DictationTuning.usesPolishEnglishProfile([]))
    }

    @Test("Quiet input is raised to the target peak without clipping, and padded")
    func quietGain() {
        let samples: [Float] = (0..<rate).map { Float(sin(Double($0) * 0.05)) * 0.1 }
        let out = DictationTuning.parakeetAudio(samples)
        #expect(out.count == samples.count + prefix + suffix)
        #expect(out.prefix(prefix).allSatisfy { $0 == 0 })
        #expect(out.suffix(suffix).allSatisfy { $0 == 0 })
        let target = DictationTuning.parakeetQuietPeakTarget ?? 1
        #expect(abs(peak(out) - target) < 1e-4)
        #expect(peak(out) <= 1)
    }

    @Test("Gain is capped at 4x for near-silent input")
    func gainCap() {
        let samples: [Float] = (0..<rate).map { $0.isMultiple(of: 2) ? 0.01 : -0.01 }
        let out = DictationTuning.parakeetAudio(samples)
        #expect(abs(peak(out) - 0.04) < 1e-6)
    }

    @Test("Loud input and digital silence are not amplified")
    func noGain() {
        let loud: [Float] = (0..<rate).map { $0.isMultiple(of: 2) ? 0.8 : -0.8 }
        #expect(peak(DictationTuning.parakeetAudio(loud)) == 0.8)
        let silence = [Float](repeating: 0, count: rate)
        let out = DictationTuning.parakeetAudio(silence)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(out.count == silence.count + prefix + suffix)
    }

    @Test("Input that would exceed one 30 s window is not padded")
    func longInputNotPadded() {
        let samples = [Float](repeating: 0.5, count: 30 * rate)
        #expect(DictationTuning.parakeetAudio(samples).count == samples.count)
    }

    @Test("Out-of-scope profiles keep the pre-tuning Parakeet decoder configuration")
    func outOfScopeConfig() {
        let base = ASRConfig(melChunkContext: false)
        for config in [DictationTuning.parakeetConfig(usesPolishEnglishProfile: false),
                       DictationTuning.parakeetConfig(usesPolishEnglishProfile: true)] {
            #expect(config.melChunkContextOverride == base.melChunkContextOverride)
            #expect(config.tdtConfig.maxSymbolsPerStep == base.tdtConfig.maxSymbolsPerStep)
            #expect(config.tdtConfig.maxTokensPerChunk == base.tdtConfig.maxTokensPerChunk)
            #expect(config.tdtConfig.consecutiveBlankLimit == base.tdtConfig.consecutiveBlankLimit)
        }
    }

    @Test("Model fallback stays Whisper Turbo outside the measured profile")
    func fallbackModelScope() {
        #expect(DictationTuning.fallbackModel(for: []) == .largeV3Turbo)
        #expect(DictationTuning.fallbackModel(for: ["en"]) == .largeV3Turbo)
        #expect(DictationTuning.fallbackModel(for: ["en", "pl"]) == .largeV3Turbo)
        #expect(DictationTuning.fallbackModel(for: ["de", "en"]) == .largeV3Turbo)
    }
}
