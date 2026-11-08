import Foundation

/// A named set of per-app overrides (FEATURES #4, spec-appprofiles-xreview
/// SPEC.fixed.md §2.2). The app in front when recording starts picks at most
/// one profile; every field defaults to "Same as Default", and Default is the
/// existing global settings, so it is never stored separately.
///
/// A profile can only *remove* remote steps (Polishing Off) or *request* the
/// existing Cloud-gated features. It cannot turn Polishing on, set a prompt,
/// or unlock anything paid: the entitlement check stays live in the
/// coordinator. Extension point: notation (devnotation spec) adds a
/// `notation` field here rather than a second per-app map (Q1).
public struct DictationProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Matched case-insensitively. An app belongs to at most one profile.
    public var bundleIdentifiers: [String]
    /// Added to the Default vocabulary, ahead of it in the speech hint.
    public var extraTerms: [String]
    public var polishing: PolishingOverride
    public var emailLayout: LayoutOverride
    public var translation: TranslationOverride
    public var output: OutputOverride

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifiers: [String] = [],
        extraTerms: [String] = [],
        polishing: PolishingOverride = .inherit,
        emailLayout: LayoutOverride = .inherit,
        translation: TranslationOverride = .inherit,
        output: OutputOverride = .inherit
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.extraTerms = extraTerms
        self.polishing = polishing
        self.emailLayout = emailLayout
        self.translation = translation
        self.output = output
    }

    /// No "on" in v1 (Q3): a profile may only switch Polishing off.
    public enum PolishingOverride: String, Codable, Sendable, CaseIterable { case inherit, off }
    /// Whether email layout is *allowed* in this app. `MailTarget` still
    /// decides what a mail composer is.
    public enum LayoutOverride: String, Codable, Sendable, CaseIterable { case inherit, composers, off }
    /// "Review before inserting" is deliberately absent until the shared
    /// review seam (R2) exists (Q5); it will be a new case here.
    public enum OutputOverride: String, Codable, Sendable, CaseIterable { case inherit, copyOnly }

    public enum TranslationOverride: Hashable, Sendable, Codable {
        case inherit
        case off
        case target(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "inherit": self = .inherit
            case "off": self = .off
            case let value where value.hasPrefix("to:") && value.count > 3: self = .target(String(value.dropFirst(3)))
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown translation"))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .inherit: try container.encode("inherit")
            case .off: try container.encode("off")
            case .target(let code): try container.encode("to:" + code)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifiers, extraTerms, polishing, emailLayout, translation, output
    }

    /// Missing fields mean "Same as Default", so a profile written by a later
    /// build with fewer fields still loads. An unknown *value* throws, and the
    /// lossy list decode drops only that profile.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bundleIdentifiers = try c.decodeIfPresent([String].self, forKey: .bundleIdentifiers) ?? []
        extraTerms = try c.decodeIfPresent([String].self, forKey: .extraTerms) ?? []
        polishing = try c.decodeIfPresent(PolishingOverride.self, forKey: .polishing) ?? .inherit
        emailLayout = try c.decodeIfPresent(LayoutOverride.self, forKey: .emailLayout) ?? .inherit
        translation = try c.decodeIfPresent(TranslationOverride.self, forKey: .translation) ?? .inherit
        output = try c.decodeIfPresent(OutputOverride.self, forKey: .output) ?? .inherit
    }

    /// Whether this profile asks for a feature gated on the Cloud entitlement,
    /// so `cloud.account` must be refreshed for it to work (T-238 class).
    /// A Polishing-Off profile never does: email and translation run inside
    /// the cleaner, so the policy turns them off with it.
    public var requestsCloudEntitlement: Bool {
        guard polishing != .off else { return false }
        if emailLayout == .composers { return true }
        if case .target = translation { return true }
        return false
    }

    /// The stored form the editor saves: the name is capped, and Polishing Off
    /// cannot be combined with an email or translation override it would
    /// silently ignore (SPEC.fixed §2.2, test 9b).
    public func normalized() -> DictationProfile {
        var copy = self
        copy.name = String(name.prefix(Self.maxNameLength))
        if copy.polishing == .off {
            copy.emailLayout = .inherit
            copy.translation = .inherit
        }
        return copy
    }

    // MARK: Limits (SPEC.fixed §2.2)

    public static let maxProfiles = 20
    public static let maxApps = 20
    public static let maxTerms = 200
    public static let maxNameLength = 40

    /// Plainsay's own bundle ID never selects a profile (Scripts/Info.plist).
    public static let ownBundleIdentifier = "com.plainsay.dictation"
}

/// The one per-app resolver. Pure, so it is frozen with the session policy and
/// tested without a running app.
public enum DictationProfileResolver {
    public static func resolve(bundleIdentifier: String?, in profiles: [DictationProfile]) -> DictationProfile? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let id = bundleIdentifier.lowercased()
        guard id != DictationProfile.ownBundleIdentifier else { return nil }
        // First wins: a safety net, since the editor keeps an app in one profile.
        return profiles.first { profile in profile.bundleIdentifiers.contains { $0.lowercased() == id } }
    }
}

// MARK: - Persistence

extension DictationProfile {
    /// Decodes the stored list, dropping only entries that fail to decode, and
    /// logs how many were dropped (never names). Missing data → `[]`, so an
    /// update changes nothing.
    public static func decodeList(_ data: Data?) -> [DictationProfile] {
        guard let data else { return [] }
        guard let entries = try? JSONDecoder().decode([Lossy].self, from: data) else {
            Log.pipeline.error("app profiles unreadable; using none")
            return []
        }
        let profiles = entries.compactMap(\.profile)
        let dropped = entries.count - profiles.count
        if dropped > 0 {
            Log.pipeline.error("dropped \(dropped, privacy: .public) unreadable app profile(s)")
        }
        return Array(profiles.prefix(maxProfiles))
    }

    private struct Lossy: Decodable {
        let profile: DictationProfile?
        init(from decoder: Decoder) throws {
            profile = try? DictationProfile(from: decoder)
        }
    }
}

// MARK: - Editor model (pure, so the limits are unit-tested)

public enum DictationProfileEditError: Error, Equatable, Sendable {
    case tooManyProfiles
    case tooManyApps
    case tooManyTerms
    case invalidName
}

extension Array where Element == DictationProfile {
    /// The profile that already claims `bundleIdentifier`, other than `excluding`.
    public func owner(of bundleIdentifier: String, excluding: UUID? = nil) -> DictationProfile? {
        let id = bundleIdentifier.lowercased()
        return first { $0.id != excluding && $0.bundleIdentifiers.contains { $0.lowercased() == id } }
    }

    public mutating func addProfile(named name: String) throws -> DictationProfile {
        guard count < DictationProfile.maxProfiles else { throw DictationProfileEditError.tooManyProfiles }
        let profile = try DictationProfile.validated(name: name)
        append(profile)
        return profile
    }

    /// Assigns an app to one profile, moving it out of any other ("Move it
    /// here?" is asked by the caller before this runs).
    public mutating func assign(_ bundleIdentifier: String, to profileID: UUID) throws {
        guard let index = firstIndex(where: { $0.id == profileID }) else { return }
        let id = bundleIdentifier.lowercased()
        guard !self[index].bundleIdentifiers.contains(where: { $0.lowercased() == id }) else { return }
        guard self[index].bundleIdentifiers.count < DictationProfile.maxApps else {
            throw DictationProfileEditError.tooManyApps
        }
        for other in indices where other != index {
            self[other].bundleIdentifiers.removeAll { $0.lowercased() == id }
        }
        self[index].bundleIdentifiers.append(bundleIdentifier)
    }

    public mutating func addTerm(_ term: String, to profileID: UUID) throws {
        guard let index = firstIndex(where: { $0.id == profileID }) else { return }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard self[index].extraTerms.count < DictationProfile.maxTerms else {
            throw DictationProfileEditError.tooManyTerms
        }
        guard !self[index].extraTerms.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        self[index].extraTerms.append(trimmed)
    }
}

extension DictationProfile {
    public static func validated(name: String) throws -> DictationProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else { throw DictationProfileEditError.invalidName }
        return DictationProfile(name: trimmed)
    }

    /// How many Default terms the 800-char speech hint will cut because this
    /// profile's terms go first ("N terms may not fit"). They still get local
    /// corrections.
    public func overflowCount(defaultDictionary: TermDictionary, maxCharacters: Int = 800) -> Int {
        // Same budget rule as `TermDictionary.asrPrompt`: each term costs its
        // length + 2, and the first term that does not fit ends the list.
        let all = TermDictionary(terms: extraTerms + defaultDictionary.terms).normalizedTerms
        var length = 0
        var included = 0
        for term in all {
            if length + term.count + 2 > maxCharacters { break }
            length += term.count + 2
            included += 1
        }
        return all.count - included
    }
}
