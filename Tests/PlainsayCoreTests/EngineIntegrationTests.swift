import AVFoundation
import Foundation
import Testing
@testable import PlainsayCore

/// Renders speech at exactly the format both local engines expect, so the
/// integration suites need no audio fixture in the repository.
private func synthesizeSpeech(_ phrase: String, voice: String? = nil) throws -> [Float] {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("plainsay-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = [
        "-o", url.path,
        // AIFF is big-endian, so little-endian float needs WAVE explicitly.
        "--file-format=WAVE",
        "--data-format=LEF32@16000",
    ]
    if let voice {
        say.arguments?.append(contentsOf: ["-v", voice])
    }
    say.arguments?.append(phrase)
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0, "say failed")

    let file = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: whisperSampleRate,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(file.length)
    )!
    try file.read(into: buffer)

    let channel = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

/// Exercises the real WhisperKit engine against real audio.
///
/// Off by default: it needs the ~632MB model on disk and takes seconds, not
/// milliseconds. Run it with `PLAINSAY_INTEGRATION=1 swift test`.
@Suite(
    "Speech engine (integration)",
    .enabled(if: ProcessInfo.processInfo.environment["PLAINSAY_INTEGRATION"] == "1")
)
struct EngineIntegrationTests {
    @Test("Transcribes synthesized speech with the real model", .timeLimit(.minutes(5)))
    func transcribesRealAudio() async throws {
        let samples = try synthesizeSpeech("The quick brown fox jumps over the lazy dog.")
        #expect(samples.count > Int(whisperSampleRate))

        let engine = WhisperKitEngine(model: .largeV3Turbo, spokenLanguages: ["en"])
        try await engine.prepare()

        let transcript = try await engine.transcribe(samples: samples, prompt: nil)

        let lowered = transcript.lowercased()
        #expect(lowered.contains("quick brown fox"), "got: \(transcript)")
        #expect(lowered.contains("lazy dog"), "got: \(transcript)")
    }

    @Test("Quiet speech is still transcribed, not suppressed as silence", .timeLimit(.minutes(5)))
    func quietSpeechSurvives() async throws {
        // Scaled down to roughly the level a real dictation measured at
        // (peak ~0.11), which the decoder was dropping as silence.
        let loud = try synthesizeSpeech("The meeting is on Thursday at four.")
        let peak = loud.map(abs).max() ?? 1
        let quiet = loud.map { $0 * (0.11 / max(peak, 0.0001)) }

        let engine = WhisperKitEngine(model: .largeV3Turbo, spokenLanguages: ["en"])
        try await engine.prepare()
        let transcript = try await engine.transcribe(samples: quiet, prompt: nil)

        #expect(!transcript.isEmpty, "quiet speech was dropped")
        #expect(transcript.lowercased().contains("thursday"), "got: \(transcript)")
    }

    @Test("Silence transcribes to nothing rather than a hallucination", .timeLimit(.minutes(5)))
    func silenceProducesNothing() async throws {
        let silence = [Float](repeating: 0, count: Int(whisperSampleRate * 2))

        let engine = WhisperKitEngine(model: .largeV3Turbo, spokenLanguages: ["en"])
        try await engine.prepare()

        let transcript = try await engine.transcribe(samples: silence, prompt: nil)

        // Whisper is known to invent text on silence; the normalizer plus
        // `noSpeechThreshold` should keep this short at worst.
        #expect(transcript.count < 30, "got: \(transcript)")
    }
}

/// Exercises the real multilingual Parakeet model. Kept behind its own flag so
/// the normal Whisper integration run does not unexpectedly download a second
/// large model.
@Suite(
    "Parakeet speech engine (integration)",
    .enabled(if: ProcessInfo.processInfo.environment["PLAINSAY_PARAKEET_INTEGRATION"] == "1")
)
struct ParakeetIntegrationTests {
    @Test("Transcribes both Polish and English", .timeLimit(.minutes(10)))
    func transcribesPolishAndEnglish() async throws {
        let english = try synthesizeSpeech("The quick brown fox jumps over the lazy dog.")
        let polish = try synthesizeSpeech(
            "Dzisiaj jest piękna pogoda w Warszawie.",
            voice: "Zosia"
        )

        let engine = ParakeetEngine()
        try await engine.prepare()

        let englishTranscript = try await engine.transcribe(samples: english, prompt: nil)
        let polishTranscript = try await engine.transcribe(samples: polish, prompt: nil)
        await engine.shutdown()

        #expect(englishTranscript.lowercased().contains("quick brown fox"), "got: \(englishTranscript)")
        let foldedPolish = polishTranscript
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
        #expect(foldedPolish.contains("warszaw"), "got: \(polishTranscript)")
        #expect(foldedPolish.contains("pogoda"), "got: \(polishTranscript)")
    }
}
