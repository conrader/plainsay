import CryptoKit
import FluidAudio
import Foundation
import PlainsayCore

struct DictationQualityEval {
    private enum LocaleID: String, Codable, CaseIterable {
        case polish = "pl_pl"
        case english = "en_us"

        var spellOutFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .spellOut
            formatter.locale = Locale(identifier: String(rawValue.prefix(3)) + rawValue.suffix(2).uppercased())
            return formatter
        }
    }

    private struct Clip {
        let locale: LocaleID
        let clipID: String
        let audioHash: String
        let referenceHash: String
    }

    private struct ClipResult: Codable {
        let locale: LocaleID
        let clipID: String
        let reference: String
        let hypothesis: String
        let errors: Int
        let referenceWords: Int
        let latencySeconds: Double
    }

    private struct LanguageResult: Codable {
        let clips: Int
        let errors: Int
        let referenceWords: Int
        let wer: Double
    }

    private struct Report: Codable {
        let model: String
        let languages: [String: LanguageResult]
        let meanLatencySeconds: Double
        let p90LatencySeconds: Double
        let score: Double
        let clips: [ClipResult]?
    }

    private struct EvalError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @MainActor
    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 3, ["dev", "heldout"].contains(arguments[0]) else {
            throw EvalError("usage: BenchmarkCLI dictation-eval {dev|heldout} <manifest.tsv> <data-root>")
        }
        let split = arguments[0]
        let manifest = URL(fileURLWithPath: arguments[1])
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let clips = try readManifest(manifest, countPerLanguage: split == "dev" ? 60 : 40)
        let suite = "PlainsayDictationEval.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw EvalError("cannot create isolated settings")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        // Set the profile before loading the model fallback from settings.
        PlainsaySettings(defaults: defaults).spokenLanguages = ["pl", "en"]
        let settings = PlainsaySettings(defaults: defaults)
        let dictionary = settings.dictionary
        let rules = settings.replacementRules
        let cleaner = NoCleanup()
        let modelCache = root.appending(path: "models")
        ModelHub.offlineMode = true
        let engine = ProviderFactory.makeOnDeviceEngine(settings, modelCache: modelCache, onState: { _ in })
        progress("Preparing \(settings.model.rawValue) for \(split)")
        try await engine.prepare()
        progress("Engine ready. Scoring \(clips.count) clips.")

        let formatters = Dictionary(uniqueKeysWithValues: LocaleID.allCases.map { ($0, $0.spellOutFormatter) })
        let clock = ContinuousClock()
        var results: [ClipResult] = []
        for (index, clip) in clips.enumerated() {
            let path = root.appending(path: "clips").appending(path: clip.locale.rawValue)
            let audio = path.appending(path: clip.clipID + ".wav")
            let reference = path.appending(path: clip.clipID + ".txt")
            _ = try checkedBytes(at: audio, hash: clip.audioHash)
            let referenceText = String(decoding: try checkedBytes(at: reference, hash: clip.referenceHash), as: UTF8.self)
            let samples = try loadSamples(path: audio.path)
            guard !samples.isEmpty else { throw EvalError("no decoded samples for \(clip.clipID)") }

            let started = clock.now
            let raw = try await engine.transcribe(samples: samples, prompt: dictionary.asrPrompt())
            var final = raw
            if !raw.isEmpty {
                let corrected = dictionary.applyCorrections(to: raw)
                let cleaned = try await cleaner.clean(corrected, dictionary: dictionary, style: .plain)
                final = finalizeDictationText(cleaned, rules: rules)
            }
            let elapsed = started.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18

            guard let formatter = formatters[clip.locale] else { throw EvalError("missing locale formatter") }
            let words = scoringWords(referenceText, formatter: formatter)
            guard !words.isEmpty else { throw EvalError("empty reference for \(clip.clipID)") }
            let (errors, count) = wordErrorRate(reference: words, hypothesis: scoringWords(final, formatter: formatter))
            results.append(ClipResult(locale: clip.locale, clipID: clip.clipID, reference: referenceText,
                                      hypothesis: final, errors: errors, referenceWords: count, latencySeconds: seconds))
            if (index + 1).isMultiple(of: 20) {
                progress("Scored \(index + 1)/\(clips.count) clips")
            }
        }
        await engine.shutdown()

        let languages = Dictionary(uniqueKeysWithValues: LocaleID.allCases.map { locale in
            let subgroup = results.filter { $0.locale == locale }
            let errors = subgroup.reduce(0) { $0 + $1.errors }
            let words = subgroup.reduce(0) { $0 + $1.referenceWords }
            return (locale.rawValue, LanguageResult(clips: subgroup.count, errors: errors,
                                                    referenceWords: words, wer: Double(errors) / Double(words)))
        })
        let latencies = results.map(\.latencySeconds).sorted()
        let p90 = latencies[Int(ceil(Double(latencies.count) * 0.9)) - 1]
        let score = languages.values.reduce(0) { $0 + $1.wer } / Double(languages.count)
        let report = Report(model: settings.model.rawValue, languages: languages,
                            meanLatencySeconds: latencies.reduce(0, +) / Double(latencies.count),
                            p90LatencySeconds: p90, score: score, clips: split == "dev" ? results : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
    }

    private static func progress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func readManifest(_ url: URL, countPerLanguage: Int) throws -> [Clip] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard lines.first == "locale\tsentence_id\tclip_id\taudio_sha256\treference_sha256" else {
            throw EvalError("unexpected manifest header")
        }
        var sentenceIDs = Set<String>()
        var clipIDs = Set<String>()
        let clips = try lines.dropFirst().map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let locale = LocaleID(rawValue: fields[0]),
                  fields[1].wholeMatch(of: /[0-9]+/) != nil, fields[2].wholeMatch(of: /[0-9]+/) != nil,
                  fields[3].wholeMatch(of: /[0-9a-f]{64}/) != nil, fields[4].wholeMatch(of: /[0-9a-f]{64}/) != nil,
                  sentenceIDs.insert(fields[1]).inserted, clipIDs.insert(fields[2]).inserted
            else { throw EvalError("invalid or repeated manifest row") }
            return Clip(locale: locale, clipID: fields[2], audioHash: fields[3],
                        referenceHash: fields[4])
        }
        guard LocaleID.allCases.allSatisfy({ locale in clips.filter { $0.locale == locale }.count == countPerLanguage })
        else { throw EvalError("unexpected number of clips per language") }
        return clips
    }

    private static func checkedBytes(at url: URL, hash: String) throws -> Data {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == hash else { throw EvalError("SHA-256 mismatch for \(url.lastPathComponent)") }
        return bytes
    }

    private static func scoringWords(_ text: String, formatter: NumberFormatter) -> [String] {
        let plain = text.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: #"(?<=\p{L})['’](?=\p{L})"#, with: "", options: .regularExpression)
        return wordTokens(plain).flatMap { token in
            guard token.wholeMatch(of: /(?:0|[1-9][0-9]{0,8})/) != nil,
                  let number = Int(token), let spelled = formatter.string(from: NSNumber(value: number))
            else { return [token] }
            return wordTokens(spelled)
        }
    }

    private static func wordTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
