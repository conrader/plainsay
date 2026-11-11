import Foundation

/// URLs, e-mail addresses and numbers (money, times, dates, versions,
/// percentages) found by one regular expression, with their ranges.
///
/// This is the regex half of `VoiceEditReview.details`, split out so callers
/// can (a) know *where* a detail sits, not only that it exists, and (b) use it
/// without the NLTagger name half. Replacement rules need both: they skip
/// matches inside a URL or e-mail span, and their factual guard must not treat
/// person, organization or place names as facts. That would suppress the
/// spelling fixes the feature exists for, such as `jason→JSON` or
/// `Kowalsky→Kowalski`.
public enum StructuredDetails {
    public enum Kind: Sendable, Equatable { case url, email, number }

    public struct Span: Sendable, Equatable {
        public let kind: Kind
        /// UTF-16 range in the string that was scanned.
        public let range: NSRange
        /// The matched text with trailing sentence punctuation trimmed, as
        /// `VoiceEditReview.details` reports it.
        public let value: String
    }

    // Same alternatives as the original single pattern in VoiceEdit.swift;
    // the capture groups only label which alternative matched.
    // Compiled per call, as before, to stay clear of Sendable questions about a
    // shared NSRegularExpression under Swift 6 strict concurrency.
    private static let pattern =
        #"(https?://[^\s<>]+)|([\w.+-]+@[\w.-]+\.[\p{L}]{2,})|([\p{Sc}]?\d+(?:[.,:/-]\d+)*(?:\s?%|[\p{Sc}])?)"#

    public static func spans(in text: String) -> [Span] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let kind: Kind = match.range(at: 1).location != NSNotFound ? .url
                : match.range(at: 2).location != NSNotFound ? .email : .number
            let value = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
            return Span(kind: kind, range: match.range, value: value)
        }
    }

    /// The set of detail values, exactly what the regex part of
    /// `VoiceEditReview.details` produced before this helper existed.
    public static func values(in text: String) -> Set<String> {
        Set(spans(in: text).map(\.value))
    }
}
