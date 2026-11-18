import Foundation

/// Resolves and looks up Plainsay's own translated strings. Both
/// `PlainsayCore` and `PlainsayApp` route through this, since the interface
/// language is a single override both modules' strings must agree on.
///
/// Deliberately independent of `Bundle.module`: `swift build` on the command
/// line (unlike Xcode) does not compile `.xcstrings` catalogs into `.lproj`
/// tables, so the source-of-truth `.xcstrings` files are compiled by
/// `Scripts/bundle.sh` straight into `Contents/Resources/<lang>.lproj/` —
/// real Cocoa localization, found via `Bundle.main` the normal way. A
/// `swift run` build (no bundle.sh) simply has no compiled tables there, and
/// every lookup below falls back to its English default — the same
/// fail-open behavior the rest of this codebase already uses for anything
/// optional (see `VoiceFilterEngine`).
public enum Localization {
    /// Mirrors `PlainsaySettings.shared.interfaceLanguage`. Kept as a plain
    /// value updated by that setter rather than read live from
    /// `PlainsaySettings`, because lookups happen from engines and other
    /// background contexts that are not on the main actor.
    nonisolated(unsafe) private static var overrideCode: String?

    @MainActor
    public static func setOverride(_ code: String?) {
        overrideCode = code
    }

    /// The language actually in effect right now: the explicit override if
    /// one is set and shipped, else the best match against the system's
    /// preferred languages, else English.
    public static var resolvedCode: String { resolvedCode(override: overrideCode) }

    /// Same resolution, but takes the override explicitly rather than
    /// reading the stored one — lets a SwiftUI view pass
    /// `settings.interfaceLanguage` directly, so `.environment(\.locale, ...)`
    /// stays reactive to that `@Observable` property instead of reading a
    /// plain static that SwiftUI cannot track.
    public static func resolvedCode(override: String?) -> String {
        if let override, AppLanguage.supportedCodes.contains(override) {
            return override
        }
        for preferred in Locale.preferredLanguages {
            let primary = primaryTag(preferred)
            if let match = AppLanguage.supportedCodes.first(where: { primaryTag($0) == primary }) {
                return match
            }
        }
        return "en"
    }

    /// Looks up `key` in `table` for the resolved language, falling back to
    /// English, then to `fallback` if neither ships that key — a missing
    /// translation degrades to readable English, never a raw key or crash.
    public static func string(_ key: String, table: String, fallback: String) -> String {
        string(key, table: table, fallback: fallback, language: resolvedCode, root: .main)
    }

    /// Same lookup with the language and the bundle holding the `.lproj`
    /// folders passed in, so tests can point it at a fixture bundle without
    /// touching the shared override.
    static func string(_ key: String, table: String, fallback: String, language: String, root: Bundle) -> String {
        lookup(key, table: table, language: language, root: root)?.value ?? fallback
    }

    /// The table value for `key` together with the language whose table
    /// supplied it — `language` itself, or English when that language does
    /// not ship the key. `nil` when neither does.
    private static func lookup(
        _ key: String, table: String, language: String, root: Bundle
    ) -> (value: String, language: String)? {
        for candidate in [language, "en"] {
            guard let path = root.path(forResource: candidate, ofType: "lproj"),
                  let bundle = Bundle(path: path)
            else { continue }
            let sentinel = "\u{0}"
            let value = bundle.localizedString(forKey: key, value: sentinel, table: table)
            if value != sentinel { return (value, candidate) }
        }
        return nil
    }

    /// `PlainsayApp`'s own strings, table "Localizable" — the same default
    /// table SwiftUI's `Text(_:)` reads, so a literal `Text("...")` and an
    /// explicit `Localization.appString(...)` call for the same English text
    /// resolve to the same translation.
    public static func appString(_ key: String, fallback: String) -> String {
        string(key, table: "Localizable", fallback: fallback)
    }

    /// `PlainsayCore`'s own strings — engine/provider error messages, model
    /// and provider display names — table "CoreLocalizable".
    public static func coreString(_ key: String, fallback: String) -> String {
        string(key, table: "CoreLocalizable", fallback: fallback)
    }

    /// Same as `appString`, but the looked-up value is a `String(format:)`
    /// template (`%@` for a string, `%d` for a count) filled in with `args`.
    /// Used instead of Swift string interpolation so the *word order* around
    /// an interpolated value can differ per language — interpolation bakes
    /// English word order into the key itself.
    public static func appFormat(_ key: String, fallback: String, _ args: CVarArg...) -> String {
        String(format: appString(key, fallback: fallback), arguments: args)
    }

    /// A count-dependent `appString`: the catalog entry carries plural
    /// variations (compiled by `xcstringstool` into a `.stringsdict`), and
    /// formatting it with an explicit locale is what makes Foundation pick
    /// the right variant ("1 termin", "2 terminy", "5 terminów"). The locale
    /// is the language whose table supplied the template — the in-app
    /// language, or English when that language lacks the key — so an
    /// override picks its own plural rules, and an English template is never
    /// inflected by another language's rules (Russian `one` covers 21).
    /// `fallback` is returned as-is when no table ships the key, so callers
    /// pass it already filled in.
    public static func appPlural(_ key: String, fallback: String, count: Int) -> String {
        plural(key, table: "Localizable", fallback: fallback, count: count, language: resolvedCode, root: .main)
    }

    static func plural(
        _ key: String, table: String, fallback: String, count: Int, language: String, root: Bundle
    ) -> String {
        guard let found = lookup(key, table: table, language: language, root: root) else { return fallback }
        return String(format: found.value, locale: Locale(identifier: found.language), count)
    }

    public static func coreFormat(_ key: String, fallback: String, _ args: CVarArg...) -> String {
        String(format: coreString(key, fallback: fallback), arguments: args)
    }

    private static func primaryTag(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
            ?? identifier.lowercased()
    }
}
