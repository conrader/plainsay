import AVFoundation
import Foundation
import Testing
@testable import PlainsayCore

/// A long dictation must keep its tail.
///
/// FluidAudio 0.15.6 could decode a whole ~15 s Parakeet TDT v3 window to
/// nothing (FluidInference/FluidAudio#909): a 43.5 s dictation came back as
/// 450 characters that stopped mid-sentence, with the voice filter having
/// kept 42.2 s of it. Upstream recovers such windows from 0.15.8 (#910).
///
/// This runs 35–60 s of real read speech — the committed LibriSpeech clips,
/// concatenated from several starting points — plus synthesized speech
/// through the shipped `ParakeetEngine`, and checks that the words spoken
/// after the first 25 s are in the transcript.
///
/// Off by default: it needs the Parakeet model (~500 MB) and Apple silicon,
/// so it cannot run in CI. Run it with
///
///     PLAINSAY_PARAKEET_INTEGRATION=1 swift test --filter ParakeetLongAudio
///
/// Set `CFFIXED_USER_HOME` to a scratch directory to download the model there
/// instead of reusing (and possibly re-verifying) the installed app's copy.
@Suite(
    "Parakeet long dictation (integration)",
    .enabled(if: ProcessInfo.processInfo.environment["PLAINSAY_PARAKEET_INTEGRATION"] == "1")
)
struct ParakeetLongAudioTests {
    /// Where the tail starts: the first 25 s are allowed to be the only part
    /// that decodes on a bad version, and that is exactly what must not pass.
    static let tailStart = 25.0

    struct Segment {
        let words: [String]
        let start: Double
    }

    struct Case {
        let name: String
        let samples: [Float]
        let segments: [Segment]
    }

    @Test("Words spoken after 25 s survive in 35–60 s dictations", .timeLimit(.minutes(20)))
    func tailIsTranscribed() async throws {
        var cases = try libriSpeechCases()
        cases.append(try synthesizedCase())

        let engine = ParakeetEngine(language: "en")
        try await engine.prepare()

        var failures: [String] = []
        for testCase in cases {
            let transcript = try await engine.transcribe(samples: testCase.samples, prompt: nil)
            let hypothesis = Self.words(transcript)
            let reference = testCase.segments.flatMap(\.words)
            let tail = testCase.segments.filter { $0.start >= Self.tailStart }.flatMap(\.words)
            let tailRecall = Self.recall(of: tail, in: hypothesis)
            let overallRecall = Self.recall(of: reference, in: hypothesis)
            let duration = Double(testCase.samples.count) / whisperSampleRate
            print(String(
                format: "LONGTAIL %@ audio=%.1fs refWords=%d hypWords=%d chars=%d tailWords=%d tailRecall=%.2f recall=%.2f",
                testCase.name, duration, reference.count, hypothesis.count, transcript.count,
                tail.count, tailRecall, overallRecall
            ))
            // A lost window costs 11–13 s of speech, which takes recall far
            // below what ordinary recognition errors explain: on 0.15.6 the
            // worst case here kept 70 % of its words and 66 % of its tail.
            // The bar is not higher because 0.15.8 (and 0.17.7) still drop
            // the last clip of two cases on a knife edge — libri-35-35s keeps
            // 85 % / 75 %, and 1 s of extra trailing silence recovers it but 2 s does not.
            // A short tail (one clip) is too noisy to judge on its own.
            if overallRecall < 0.8 || (tail.count >= 20 && tailRecall < 0.7) {
                failures.append(
                    "\(testCase.name): tail recall \(String(format: "%.2f", tailRecall)), "
                        + "recall \(String(format: "%.2f", overallRecall)) — got: \(transcript)"
                )
            }
        }
        await engine.shutdown()
        #expect(failures.isEmpty, "tail lost: \(failures.joined(separator: "; "))")
    }

    // MARK: - Fixtures

    private struct Utterance: Decodable {
        let id: String
        let reference: String
        let flac: String
    }

    /// Back-to-back LibriSpeech clips with a short pause between them, the
    /// way someone dictates sentence after sentence.
    private func libriSpeechCases() throws -> [Case] {
        let data = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Benchmark/data")
        let manifest = try JSONDecoder().decode(
            [Utterance].self,
            from: Data(contentsOf: data.appending(path: "librispeech-test-clean-manifest.json"))
        )
        let clips = try manifest.map { (words: Self.words($0.reference), samples: try Self.load(data.appending(path: $0.flac))) }
        let pause = [Float](repeating: 0, count: Int(whisperSampleRate * 0.4))

        var cases: [Case] = []
        for first in stride(from: 0, to: clips.count, by: 5) {
            for target in [35.0, 43.5, 52.0, 60.0] {
                var samples: [Float] = []
                var segments: [Segment] = []
                var index = first
                while Double(samples.count) / whisperSampleRate < target {
                    let clip = clips[index % clips.count]
                    segments.append(Segment(words: clip.words, start: Double(samples.count) / whisperSampleRate))
                    samples += clip.samples + pause
                    index += 1
                }
                // Short targets can round up to the same clips as a longer one.
                guard cases.last?.samples.count != samples.count else { continue }
                cases.append(Case(name: "libri-\(first)-\(Int(target))s", samples: samples, segments: segments))
            }
        }
        return cases
    }

    private func synthesizedCase() throws -> Case {
        let sentences = [
            "This is a long dictation that keeps going well past half a minute.",
            "The first part talks about the weather, which has been cold and windy all week.",
            "After lunch we walked to the harbour and watched the ferries come in.",
            "My sister wants to repaint the kitchen a pale shade of green before winter.",
            "The library opens at nine and closes early on Saturdays and Sundays.",
            "Please remember to send the invoice to the accountant by Friday afternoon.",
            "The garden needs water, the car needs new tyres, and the dog needs a walk.",
            "Tomorrow the train leaves at seven, so we should pack everything tonight.",
            "Our neighbours are planning a small party for the end of the month.",
            "The final sentence mentions purple elephants dancing on a silver bridge.",
        ]
        let pause = [Float](repeating: 0, count: Int(whisperSampleRate * 0.4))
        var samples: [Float] = []
        var segments: [Segment] = []
        for sentence in sentences {
            segments.append(Segment(words: Self.words(sentence), start: Double(samples.count) / whisperSampleRate))
            samples += try synthesizeSpeech(sentence) + pause
        }
        return Case(name: "say", samples: samples, segments: segments)
    }

    // MARK: - Scoring

    static func words(_ text: String) -> [String] {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        return String(cleaned).split(separator: " ").map(String.init)
    }

    /// Fraction of `expected` words found in `hypothesis`, counted as a
    /// multiset so a repeated common word is not credited twice.
    static func recall(of expected: [String], in hypothesis: [String]) -> Double {
        guard !expected.isEmpty else { return 1 }
        var available = Dictionary(hypothesis.map { ($0, 1) }, uniquingKeysWith: +)
        var found = 0
        for word in expected where (available[word] ?? 0) > 0 {
            available[word]! -= 1
            found += 1
        }
        return Double(found) / Double(expected.count)
    }

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false
        )!
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
        let input = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * whisperSampleRate / file.processingFormat.sampleRate) + 1024
        let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let channel = try #require(output.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
