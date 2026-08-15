import Foundation

/// User-supplied vocabulary: names, jargon, and product names that speech
/// models mangle phonetically. Engines with prompt support use it to bias ASR;
/// every engine can use it to repair spellings during cleanup.
public struct TermDictionary: Codable, Sendable, Equatable {
    public var terms: [String]

    public init(terms: [String] = []) {
        self.terms = terms
    }

    public var isEmpty: Bool { normalizedTerms.isEmpty }

    /// Trimmed, de-duplicated, order-preserving.
    public var normalizedTerms: [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Prompt text conditioning Whisper's decoder toward these spellings.
    ///
    /// Whisper's `initial_prompt` works best as natural prose rather than a bare
    /// list, and it is capped by the model's context — keep it short.
    public func asrPrompt(maxCharacters: Int = 800) -> String? {
        let terms = normalizedTerms
        guard !terms.isEmpty else { return nil }

        var included: [String] = []
        var length = 0
        for term in terms {
            let cost = term.count + 2
            if length + cost > maxCharacters { break }
            included.append(term)
            length += cost
        }
        guard !included.isEmpty else { return nil }
        return "Glossary: " + included.joined(separator: ", ") + "."
    }

    /// Term list injected into the cleanup prompt so the LLM can fix spellings
    /// the decoder got wrong.
    public func cleanupHint() -> String? {
        let terms = normalizedTerms
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }
}
