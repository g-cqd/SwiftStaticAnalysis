//  GlobMatcher.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - GlobMatcher

/// Single canonical glob → regex translation used everywhere in the package.
///
/// Anchored `wholeMatch` semantics: a single `.swa.json` exclusion
/// entry like `Tests` matches only the literal filename, not any path
/// containing the segment. The MCP and CLI surfaces both route through
/// here so the same pattern behaves identically everywhere.
///
/// Supported glob tokens:
///
/// - `**` — match any sequence of characters, including `/`.
/// - `**/` — match any number of intermediate directory segments
///   (including zero), so `**/Tests/**` matches `Tests/...` and
///   `a/b/Tests/x/y` equally.
/// - `*` — match any sequence not containing `/`.
/// - `?` — match a single character that is not `/`.
///
/// All other characters are matched literally; regex metacharacters in the
/// pattern are escaped before compilation, so a user pattern that happens
/// to contain `+`, `[`, `(`, etc. is treated as the literal text the user
/// almost certainly intended.
///
/// The compiled regex is anchored at both ends (`^...$`) and constructed
/// through ``SafeRegex/compile(_:)`` so the same length cap and ReDoS
/// prefilter apply to globs as to MCP `search_symbols` regex queries.
public enum GlobMatcher {
    /// Returns `true` when `path` matches `pattern` under glob semantics.
    /// A pattern that fails to compile (e.g. the pattern itself is
    /// pathological per `SafeRegex`'s prefilter) does not match — this
    /// matches the historical defensive default.
    public static func matches(path: String, pattern: String) -> Bool {
        guard let regex = compile(pattern: pattern) else { return false }
        return path.wholeMatch(of: regex) != nil
    }

    /// Like ``matches(path:pattern:)`` but routes the three most common
    /// project-level patterns (`**/Tests/**`, `**/*Tests.swift`,
    /// `**/Fixtures/**`) through hand-tuned predicates that skip regex
    /// compilation entirely. The fallback for anything else is the
    /// canonical anchored-regex path.
    ///
    /// Moved out of `UnusedCodeDetector.UnusedCodeFilter.matchesGlobPattern`
    /// in Phase 3.2 of the audit-driven cleanup so file discovery
    /// (in Core / CLI / MCP / bench) no longer pulls in
    /// `UnusedCodeDetector` just to honour the fast paths.
    public static func matchesWithFastPaths(path: String, pattern: String) -> Bool {
        switch pattern {
        case "**/Tests/**":
            return pathMatchesTestsGlob(path)
        case "**/*Tests.swift":
            return pathMatchesTestFileSuffixGlob(path)
        case "**/Fixtures/**":
            return pathMatchesFixturesGlob(path)
        default:
            return matches(path: path, pattern: pattern)
        }
    }

    /// Compile `pattern` to the canonical anchored regex. Returns `nil` if
    /// the translated pattern is rejected by `SafeRegex` (length cap or
    /// ReDoS prefilter) or fails to compile.
    public static func compile(pattern: String) -> Regex<AnyRegexOutput>? {
        let regexBody = translate(pattern: pattern)
        let anchored = "^\(regexBody)$"
        return try? SafeRegex.compile(anchored)
    }

    /// Translate the glob `pattern` to the un-anchored regex body. Public
    /// for tests; production callers should use ``matches(path:pattern:)``
    /// or ``compile(pattern:)``.
    public static func translate(pattern: String) -> String {
        // Use sentinel placeholders so the regex escape pass below doesn't
        // accidentally escape the glob wildcards themselves.
        let doubleStarSlash = "\u{0000}DOUBLE_STAR_SLASH\u{0000}"
        let doubleStar = "\u{0000}DOUBLE_STAR\u{0000}"
        let singleStar = "\u{0000}SINGLE_STAR\u{0000}"
        let question = "\u{0000}QUESTION\u{0000}"

        var working =
            pattern
            .replacingOccurrences(of: "**/", with: doubleStarSlash)
            .replacingOccurrences(of: "**", with: doubleStar)
            .replacingOccurrences(of: "*", with: singleStar)
            .replacingOccurrences(of: "?", with: question)

        // Order matters here — backslash must be escaped first or it
        // double-escapes the escaping we add next.
        let metaCharacters: [(needle: String, replacement: String)] = [
            ("\\", "\\\\"),
            (".", "\\."),
            ("^", "\\^"),
            ("$", "\\$"),
            ("+", "\\+"),
            ("(", "\\("),
            (")", "\\)"),
            ("[", "\\["),
            ("]", "\\]"),
            ("{", "\\{"),
            ("}", "\\}"),
            ("|", "\\|"),
        ]
        for (needle, replacement) in metaCharacters {
            working = working.replacingOccurrences(of: needle, with: replacement)
        }

        return
            working
            .replacingOccurrences(of: doubleStarSlash, with: "(?:.*/)?")
            .replacingOccurrences(of: doubleStar, with: ".*")
            .replacingOccurrences(of: singleStar, with: "[^/]*")
            .replacingOccurrences(of: question, with: "[^/]")
    }
}
