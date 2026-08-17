import AVFoundation
import Foundation
import PlainsayCore

/// Self-benchmark: Plainsay's own on-device engines (WhisperKit, Parakeet)
/// against a public dataset with published reference transcripts, measuring
/// word error rate and latency. No third-party app is run — this is not a
/// head-to-head against a competitor's software, just an honest, reproducible
/// measurement of what Plainsay itself does. See docs/BENCHMARK.md for the
/// full methodology and how to reproduce this.
///
/// Usage: BenchmarkCLI <path-to-manifest.json>
///
/// manifest.json is an array of {id, speaker, chapter, reference, flac}
/// (flac is a path relative to the manifest's own directory).

struct Utterance: Codable {
    let id: String
    let speaker: String
    let chapter: String
    let reference: String
    let flac: String
}

struct EngineResult {
    var hypotheses: [String: String] = [:]
    var latencies: [String: Double] = [:]
    var errors: [String: String] = [:]
}

/// Loads a FLAC (or any AVFoundation-readable) file and resamples to 16kHz
/// mono Float32 — the exact format every TranscriptionEngine expects, matching
/// what AudioRecorder captures live.
func loadSamples(path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    guard let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false
    ) else {
        throw NSError(domain: "BenchmarkCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad target format"])
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw NSError(domain: "BenchmarkCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "no converter"])
    }

    let frameCount = AVAudioFrameCount(file.length)
    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
        throw NSError(domain: "BenchmarkCLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "no input buffer"])
    }
    try file.read(into: inputBuffer)

    let outCapacity = AVAudioFrameCount(Double(frameCount) * whisperSampleRate / sourceFormat.sampleRate) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
        throw NSError(domain: "BenchmarkCLI", code: 4, userInfo: [NSLocalizedDescriptionKey: "no output buffer"])
    }

    var error: NSError?
    var consumed = false
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        if consumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return inputBuffer
    }
    if let error { throw error }

    guard let channelData = outputBuffer.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
}

/// Normalizes text the way ASR benchmarks conventionally do before scoring:
/// lowercase, strip punctuation (keep apostrophes so "don't" stays one word),
/// collapse whitespace. Both hypothesis and reference go through this, so
/// case/punctuation differences (Whisper writes "Hello,", LibriSpeech
/// references are bare uppercase words) don't count as errors they aren't.
func normalize(_ text: String) -> [String] {
    let lowered = text.lowercased()
    var cleaned = ""
    for ch in lowered {
        if ch.isLetter || ch.isNumber || ch == "'" || ch == " " {
            cleaned.append(ch)
        } else {
            cleaned.append(" ")
        }
    }
    return cleaned.split(separator: " ").map(String.init)
}

/// Word error rate via Levenshtein distance over word sequences:
/// (substitutions + deletions + insertions) / reference word count.
func wordErrorRate(reference: [String], hypothesis: [String]) -> (errors: Int, refWords: Int) {
    let n = reference.count, m = hypothesis.count
    if n == 0 { return (m, 0) }
    var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { dp[i][0] = i }
    for j in 0...m { dp[0][j] = j }
    for i in 1...n {
        for j in 1...m {
            if reference[i - 1] == hypothesis[j - 1] {
                dp[i][j] = dp[i - 1][j - 1]
            } else {
                dp[i][j] = 1 + min(dp[i - 1][j - 1], dp[i - 1][j], dp[i][j - 1])
            }
        }
    }
    return (dp[n][m], n)
}

@main
struct BenchmarkCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: BenchmarkCLI <manifest.json>")
            exit(1)
        }
        let manifestURL = URL(fileURLWithPath: args[1])
        let manifestDir = manifestURL.deletingLastPathComponent()

        let utterances: [Utterance]
        do {
            let data = try Data(contentsOf: manifestURL)
            utterances = try JSONDecoder().decode([Utterance].self, from: data)
        } catch {
            print("failed to read manifest: \(error)")
            exit(1)
        }
        print("Loaded \(utterances.count) utterances from \(manifestURL.path)")

        // Preload every clip's samples once, up front, so engine timing below
        // measures transcription only, not file I/O.
        var samplesByID: [String: [Float]] = [:]
        var durationByID: [String: Double] = [:]
        for u in utterances {
            let path = manifestDir.appendingPathComponent(u.flac).path
            do {
                let samples = try loadSamples(path: path)
                samplesByID[u.id] = samples
                durationByID[u.id] = Double(samples.count) / whisperSampleRate
            } catch {
                print("  ! failed to load \(u.id): \(error)")
            }
        }
        print("Decoded \(samplesByID.count) clips, total \(String(format: "%.1f", durationByID.values.reduce(0, +)))s audio")

        var results: [String: EngineResult] = [:]

        // --- Whisper (large-v3-turbo, the shipped default) ---
        print("\n=== Whisper large-v3-turbo ===")
        let whisper = WhisperKitEngine(model: .largeV3Turbo, spokenLanguages: ["en"])
        do {
            try await whisper.prepare()
            var r = EngineResult()
            for u in utterances {
                guard let samples = samplesByID[u.id] else { continue }
                let start = Date()
                do {
                    let text = try await whisper.transcribe(samples: samples, prompt: nil)
                    r.hypotheses[u.id] = text
                    r.latencies[u.id] = Date().timeIntervalSince(start)
                } catch {
                    r.errors[u.id] = "\(error)"
                }
                print("  \(u.id): \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            }
            results["whisper-large-v3-turbo"] = r
        } catch {
            print("  ! whisper prepare failed: \(error)")
        }
        await whisper.shutdown()

        // --- Parakeet TDT 0.6B v3 (the recommended default) ---
        print("\n=== Parakeet TDT 0.6B v3 ===")
        let parakeet = ParakeetEngine(language: "en")
        do {
            try await parakeet.prepare()
            var r = EngineResult()
            for u in utterances {
                guard let samples = samplesByID[u.id] else { continue }
                let start = Date()
                do {
                    let text = try await parakeet.transcribe(samples: samples, prompt: nil)
                    r.hypotheses[u.id] = text
                    r.latencies[u.id] = Date().timeIntervalSince(start)
                } catch {
                    r.errors[u.id] = "\(error)"
                }
                print("  \(u.id): \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            }
            results["parakeet-tdt-0.6b-v3"] = r
        } catch {
            print("  ! parakeet prepare failed: \(error)")
        }
        await parakeet.shutdown()

        // --- Score and report ---
        print("\n=== Results ===")
        var report: [[String: Any]] = []
        for (engineName, r) in results {
            var totalErrors = 0, totalRefWords = 0
            var perUtterance: [[String: Any]] = []
            for u in utterances {
                guard let hyp = r.hypotheses[u.id] else { continue }
                let refWords = normalize(u.reference)
                let hypWords = normalize(hyp)
                let (errors, refCount) = wordErrorRate(reference: refWords, hypothesis: hypWords)
                totalErrors += errors
                totalRefWords += refCount
                perUtterance.append([
                    "id": u.id, "reference": u.reference, "hypothesis": hyp,
                    "errors": errors, "refWords": refCount,
                    "latencySeconds": r.latencies[u.id] ?? 0,
                    "audioSeconds": durationByID[u.id] ?? 0,
                ])
            }
            let wer = totalRefWords > 0 ? Double(totalErrors) / Double(totalRefWords) : 0
            let totalLatency = r.latencies.values.reduce(0, +)
            let totalAudio = utterances.compactMap { r.latencies[$0.id] != nil ? durationByID[$0.id] : nil }.reduce(0, +)
            let rtf = totalAudio > 0 ? totalLatency / totalAudio : 0
            print("\(engineName): WER \(String(format: "%.2f", wer * 100))%  (\(totalErrors)/\(totalRefWords) words)  "
                + "avg latency \(String(format: "%.2f", totalLatency / Double(max(r.latencies.count, 1))))s  "
                + "RTF \(String(format: "%.3f", rtf))  errors: \(r.errors.count)")
            report.append([
                "engine": engineName, "werPercent": wer * 100,
                "totalErrors": totalErrors, "totalReferenceWords": totalRefWords,
                "averageLatencySeconds": totalLatency / Double(max(r.latencies.count, 1)),
                "realTimeFactor": rtf, "utteranceCount": r.latencies.count,
                "failedCount": r.errors.count,
                "utterances": perUtterance,
            ])
        }

        let outURL = manifestDir.appendingPathComponent("results.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outURL)
            print("\nWrote \(outURL.path)")
        }
    }
}
