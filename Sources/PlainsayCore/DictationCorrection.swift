import Foundation
import Observation

public enum DictationCorrectionError: LocalizedError, Equatable {
    case noMatch, ambiguousMatch, nothingToUndo, stale, cancelled, emptyCommand, tooShort, unverified

    public var errorDescription: String? {
        switch self {
        case .noMatch: "That phrase was not found in the last dictation. Include the exact words you want to change."
        case .ambiguousMatch: "That phrase appears more than once. Include more surrounding words so Plainsay can identify one occurrence."
        case .nothingToUndo: "There is no verified change to undo. Select the text in its app to edit it manually."
        case .stale: "The dictation changed or its destination is no longer available. Copy your correction and paste it manually."
        case .cancelled: "Correction cancelled."
        case .emptyCommand: "No correction was heard. Try again or type the request."
        case .tooShort: "Hold the recording a little longer and say the correction."
        case .unverified: "The replacement was sent, but the app did not confirm the result. Check its text before trying again."
        }
    }
}

public enum DictationCorrectionCommand: Equatable, Sendable {
    case replace(String, String)
    case undo
    case rewrite(String)

    public static func parse(_ transcript: String) throws -> Self {
        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw DictationCorrectionError.emptyCommand }
        let normalized = command.trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")).lowercased()
        if ["undo", "undo that", "undo last dictation", "cofnij", "cofnij to", "cofnij ostatnie dyktowanie"].contains(normalized) {
            return .undo
        }
        let patterns = [
            #"^(?:change|replace)\s+(.+?)\s+(?:to|with)\s+(.+)$"#,
            #"^(?:zmień|zamień)\s+(.+?)\s+na\s+(.+)$"#
        ]
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            let source = command as NSString
            if let match = regex.firstMatch(in: command, range: NSRange(location: 0, length: source.length)) {
                func phrase(_ index: Int) -> String {
                    let raw = source.substring(with: match.range(at: index)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let quotes = try! NSRegularExpression(pattern: #"^["“](.*)["”][.!?]?$"#, options: [.dotMatchesLineSeparators])
                    let ns = raw as NSString
                    if let quoted = quotes.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                        return ns.substring(with: quoted.range(at: 1))
                    }
                    if index == 2, raw.hasSuffix(".") { return String(raw.dropLast()) }
                    return raw
                }
                let from = phrase(1)
                let to = phrase(2)
                guard !from.isEmpty, !to.isEmpty else { throw DictationCorrectionError.emptyCommand }
                return .replace(from, to)
            }
        }
        return .rewrite(command)
    }

    public func localReplacement(in original: String, undoText: String?) throws -> String? {
        switch self {
        case .undo:
            guard let undoText else { throw DictationCorrectionError.nothingToUndo }
            return undoText
        case .rewrite: return nil
        case .replace(let from, let to):
            // A bare number must not match one component of a time, decimal,
            // date, or version ("change 10" must not silently edit "10:30").
            let numeric = from.range(of: #"^[\p{Sc}]?\d+(?:[.,:/-]\d+)*%?$"#, options: .regularExpression) != nil
            let prefix = numeric ? #"(?<![\p{N}][.,:/-])"# : ""
            let suffix = numeric ? #"(?![.,:/-][\p{N}])"# : ""
            let pattern = prefix + #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: from) + #"(?![\p{L}\p{N}_])"# + suffix
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let source = original as NSString
            let matches = regex.matches(in: original, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { throw DictationCorrectionError.noMatch }
            guard matches.count == 1 else { throw DictationCorrectionError.ambiguousMatch }
            return source.replacingCharacters(in: matches[0].range, with: to)
        }
    }
}

@MainActor
public protocol DictationReplacementTarget: AnyObject {
    var replacedText: String { get }
    func replace(with text: String) async throws
}

public struct DictationCorrectionProposal: Sendable {
    public let revision: UUID
    public let original: String
    public let replacement: String
    public let isUndo: Bool
}

/// One in-memory dictation, including its verified destination and undo stack.
/// Nothing about the destination or the surrounding document is persisted.
@MainActor
@Observable
public final class LastDictation {
    public let id = UUID()
    public let historyID: UUID?
    public private(set) var text: String
    public private(set) var revision = UUID()
    public private(set) var canReplace: Bool
    private var undoStack: [String]
    private let target: (any DictationReplacementTarget)?
    private var applying = false

    public init(text: String, target: (any DictationReplacementTarget)? = nil, historyID: UUID? = nil) {
        self.text = text
        self.historyID = historyID
        self.target = target
        self.canReplace = target != nil
        self.undoStack = target.map { [$0.replacedText] } ?? []
    }

    public var undoText: String? { undoStack.last }

    public func proposal(replacement: String, isUndo: Bool = false) -> DictationCorrectionProposal {
        DictationCorrectionProposal(revision: revision, original: text,
            replacement: sanitizeForInsertion(replacement), isUndo: isUndo)
    }

    public func apply(_ proposal: DictationCorrectionProposal) async throws {
        guard !applying, canReplace, let target, proposal.revision == revision, proposal.original == text else {
            throw DictationCorrectionError.stale
        }
        if proposal.isUndo {
            guard undoStack.last == proposal.replacement else { throw DictationCorrectionError.nothingToUndo }
        }
        applying = true
        defer { applying = false }
        do { try await target.replace(with: proposal.replacement) }
        catch {
            canReplace = false
            throw error
        }
        if proposal.isUndo { _ = undoStack.popLast() }
        else {
            undoStack.append(text)
            if undoStack.count > 10 { undoStack.removeFirst() }
        }
        text = proposal.replacement
        revision = UUID()
    }
}
