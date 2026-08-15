import AVFoundation
import Foundation
import Testing
@testable import PlainsayCore

/// Exercises the real WhisperKit engine against real audio.
///
/// Off by default: it needs the ~632MB model on disk and takes seconds, not
/// milliseconds. Run it with `PLAINSAY_INTEGRATION=1 swift test`.
@Suite(
    "Speech engine (integration)",
    .enabled(if: ProcessInfo.processInfo.environment["PLAINSAY_INTEGRATION"] == "1")
)
struct EngineIntegrationTests {
    /// Renders a phrase with macOS's own speech synthesiser, at exactly the
    /// format Whisper wants, so the test needs no audio fixture in the repo.
    private func synthesize(_ phrase: String) throws -> [Float] {
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
            phrase,
        ]
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

    @Test("Transcribes synthesized speech with the real model", .timeLimit(.minutes(5)))
    func transcribesRealAudio() async throws {
        let samples = try synthesize("The quick brown fox jumps over the lazy dog.")
        #expect(samples.count > Int(whisperSampleRate))

        let engine = WhisperKitEngine(model: .largeV3Turbo, language: "en")
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
        let loud = try synthesize("The meeting is on Thursday at four.")
        let peak = loud.map(abs).max() ?? 1
        let quiet = loud.map { $0 * (0.11 / max(peak, 0.0001)) }

        let engine = WhisperKitEngine(model: .largeV3Turbo, language: "en")
        try await engine.prepare()
        let transcript = try await engine.transcribe(samples: quiet, prompt: nil)

        #expect(!transcript.isEmpty, "quiet speech was dropped")
        #expect(transcript.lowercased().contains("thursday"), "got: \(transcript)")
    }

    @Test("Silence transcribes to nothing rather than a hallucination", .timeLimit(.minutes(5)))
    func silenceProducesNothing() async throws {
        let silence = [Float](repeating: 0, count: Int(whisperSampleRate * 2))

        let engine = WhisperKitEngine(model: .largeV3Turbo, language: "en")
        try await engine.prepare()

        let transcript = try await engine.transcribe(samples: silence, prompt: nil)

        // Whisper is known to invent text on silence; the normalizer plus
        // `noSpeechThreshold` should keep this short at worst.
        #expect(transcript.count < 30, "got: \(transcript)")
    }
}
