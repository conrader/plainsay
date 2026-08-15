import AVFoundation
import Foundation

/// What a hosted transcription endpoint is sent.
public enum AudioUploadFormat: String, Sendable, CaseIterable {
    case wav
    case m4a

    var filename: String { "audio.\(rawValue)" }

    var mimeType: String {
        switch self {
        case .wav: "audio/wav"
        case .m4a: "audio/mp4"
        }
    }
}

/// AAC-in-MP4 encoding for upload.
///
/// Two reasons this exists rather than sending the WAV we already have.
///
/// deAPI's OpenAI-compatible endpoint rejects WAV in practice — it answers
/// `upstream_validation_error` naming a list of accepted types that includes
/// `audio/wav`, and refuses every WAV regardless of the MIME type sent. m4a is
/// accepted, verified against the live service.
///
/// And it is smaller: measured at about a third of the equivalent 16-bit PCM.
/// On dictation that is felt directly, because the upload sits between
/// finishing the sentence and seeing the text.
public enum AACEncoder {
    /// Returns nil if encoding fails; callers fall back to WAV rather than
    /// losing the dictation.
    public static func encode(samples: [Float], sampleRate: Double = whisperSampleRate) -> Data? {
        guard !samples.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsay-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            // Requested, not honoured: AVAudioFile ignores this and encodes
            // around 90kbps regardless, and adding a bit-rate strategy makes it
            // worse rather than better. Left in place because it costs nothing
            // and documents the intent; getting a real 32kbps would mean
            // rebuilding this on AVAssetWriter, which is not worth it while the
            // output is already a third of the WAV.
            AVEncoderBitRateKey: 32_000,
        ]

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }

        do {
            // Scoped so the file is closed — and the MP4 container finalised —
            // before the bytes are read back. Reading while it is still open
            // yields a truncated file with no moov atom.
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
            try file?.write(from: buffer)
            file = nil
        } catch {
            Log.audio.error("AAC encoding failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        return try? Data(contentsOf: url)
    }
}
