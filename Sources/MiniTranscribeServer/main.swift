import AVFoundation
import Foundation
import PlainsayCore
import Vapor

/// A small always-warm transcription server for the Mac Mini pilot: Parakeet
/// (via FluidAudio/CoreML, ANE-accelerated — same engine and code the Mac
/// client runs on-device) loaded once at startup, reused across requests.
///
/// Wire shape deliberately mirrors the CT2 pilot server (`POST /transcribe`,
/// multipart field named `audio`, `GET /health`) so the two are directly
/// comparable and swappable in a benchmark or in api.plainsay.app's upstream
/// config later.

struct TranscribeUpload: Content {
    var audio: File
}

struct TranscribeResponse: Content {
    let text: String
    let model: String
    let duration: Double
}

/// Mirrors `BenchmarkCLI.loadSamples`: decode whatever audio container was
/// uploaded, resample to 16kHz mono Float32 — the format every
/// `TranscriptionEngine` expects.
func loadSamples(fileURL: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: fileURL)
    let sourceFormat = file.processingFormat
    guard
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false
        )
    else {
        throw Abort(.internalServerError, reason: "bad target format")
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw Abort(.internalServerError, reason: "no converter")
    }

    let frameCount = AVAudioFrameCount(file.length)
    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
        throw Abort(.internalServerError, reason: "no input buffer")
    }
    try file.read(into: inputBuffer)

    let outCapacity = AVAudioFrameCount(Double(frameCount) * whisperSampleRate / sourceFormat.sampleRate) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
        throw Abort(.internalServerError, reason: "no output buffer")
    }

    var conversionError: NSError?
    var consumed = false
    converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
        if consumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return inputBuffer
    }
    if let conversionError { throw conversionError }

    guard let channelData = outputBuffer.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
}

@main
struct MiniTranscribeServerCommand {
    static func main() async throws {
        let app = try await Application.make(.detect())

        print("Loading Parakeet TDT 0.6B v3 (this compiles the CoreML model on first run)...")
        let parakeet = ParakeetEngine(language: nil)
        try await parakeet.prepare()
        print("Parakeet ready.")

        app.get("health") { _ -> [String: Bool] in
            ["ok": true]
        }

        app.on(.POST, "transcribe", body: .collect(maxSize: "30mb")) { req -> TranscribeResponse in
            let upload = try req.content.decode(TranscribeUpload.self)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mini-transcribe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            guard let data = upload.audio.data.getData(at: 0, length: upload.audio.data.readableBytes) else {
                throw Abort(.badRequest, reason: "empty audio upload")
            }
            try data.write(to: tempURL)

            let samples = try loadSamples(fileURL: tempURL)
            guard !samples.isEmpty else {
                throw Abort(.badRequest, reason: "could not decode audio")
            }
            let duration = Double(samples.count) / whisperSampleRate

            let text = try await parakeet.transcribe(samples: samples, prompt: nil)
            return TranscribeResponse(text: text, model: "parakeet-tdt-0.6b-v3", duration: duration)
        }

        try await app.execute()
    }
}
