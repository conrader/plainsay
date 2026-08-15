import Foundation
import Testing
@testable import PlainsayCore

@Suite("AAC upload encoding")
struct AACEncoderTests {
    /// A second of a tone — real samples, so the encoder has something to do.
    private func tone(seconds: Double = 1.0) -> [Float] {
        let count = Int(seconds * whisperSampleRate)
        return (0..<count).map { i in
            sin(2 * .pi * 440 * Float(i) / Float(whisperSampleRate)) * 0.3
        }
    }

    @Test("Produces a real MP4 container")
    func producesMP4() throws {
        let data = try #require(AACEncoder.encode(samples: tone()))

        // Bytes 4..8 of an MP4 are the 'ftyp' box type. Without the container
        // being finalised this is missing and the upload is rejected.
        #expect(data.count > 100)
        #expect(String(decoding: data[4..<8], as: UTF8.self) == "ftyp")
    }

    @Test("Compresses far below 16-bit PCM")
    func muchSmallerThanWAV() throws {
        let samples = tone(seconds: 3)
        let aac = try #require(AACEncoder.encode(samples: samples))
        let wav = WAVEncoder.encode(samples: samples)

        // Measured at roughly a third on a pure tone, better on speech. The
        // upload sits between finishing a sentence and seeing the text, so this
        // ratio is latency, not just bandwidth.
        #expect(aac.count * 2 < wav.count, "AAC \(aac.count) vs WAV \(wav.count)")
    }

    @Test("Empty audio encodes to nothing rather than an empty container")
    func emptyIsNil() {
        #expect(AACEncoder.encode(samples: []) == nil)
    }

    @Test("Only deAPI is switched to m4a")
    func formatPerProvider() {
        // deAPI rejects WAV whatever MIME it is sent under; the others are
        // left on the path actually exercised against them.
        #expect(ASRProvider.deapi.uploadFormat == .m4a)
        #expect(ASRProvider.groq.uploadFormat == .wav)
        #expect(ASRProvider.openAI.uploadFormat == .wav)
        #expect(ASRProvider.custom.uploadFormat == .wav)
    }

    @Test("The multipart part carries the matching filename and type")
    func multipartMatchesFormat() {
        let body = RemoteWhisperEngine.multipartBody(
            boundary: "B", fields: [], audio: Data([1, 2, 3]),
            filename: AudioUploadFormat.m4a.filename,
            contentType: AudioUploadFormat.m4a.mimeType
        )
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.contains("filename=\"audio.m4a\""))
        #expect(text.contains("Content-Type: audio/mp4"))
    }
}
