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
    /// Phrased as a full sentence a real transcript could plausibly contain,
    /// not a "Label: term, term" list. Whisper's prompt is prior *transcript*
    /// text the decoder continues from, and "Label:" is exactly the shape of
    /// a speaker-label line in the subtitle/interview data it trained on —
    /// observed in the wild turning into a hallucinated name or fragment of
    /// the word "Glossary" pasted onto the front of real dictation (e.g. a
    /// transcript starting "Grzegorz:" or "Glosary C:" with no such word ever
    /// spoken). A natural sentence with no label-like colon at its start
    /// doesn't invite that continuation.
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
        return "This recording may mention \(Self.naturalList(included))."
    }

    /// "a", "a and b", or "a, b, and c" — deterministic regardless of the
    /// user's system locale, unlike `ListFormatter`, so the prompt this feeds
    /// to the decoder doesn't silently change shape across machines.
    private static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    /// Term list injected into the cleanup prompt so the LLM can fix spellings
    /// the decoder got wrong.
    public func cleanupHint() -> String? {
        let terms = normalizedTerms
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }
}
