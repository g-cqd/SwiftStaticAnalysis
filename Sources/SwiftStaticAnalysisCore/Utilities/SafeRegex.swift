//  SafeRegex.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import RegexBuilder

// MARK: - SafeRegex

/// Single canonical entry point for compiling attacker-controllable regex
/// patterns reachable from the MCP surface, glob translation, or any other
/// external-input path.
///
/// `SafeRegex.compile` provides two pre-emptive guards against catastrophic
/// backtracking ("ReDoS"):
///
/// 1. **Length cap.** Long patterns dramatically widen the search space for
///    backtracking engines. Patterns longer than ``maxPatternLength`` are
///    rejected outright. The default of 512 bytes is large enough for every
///    sensible glob or symbol query and tight enough to bound worst-case
///    compilation cost.
/// 2. **Static antipattern prefilter.** Nested quantifiers of the form
///    `(...*)*` / `(...+)+` are the textbook ReDoS recipe. The prefilter
///    refuses these without ever compiling the offending pattern.
///
/// Wall-clock budgeting (each match capped against a per-call deadline) is
/// the caller's responsibility — the budget is necessarily caller-specific
/// because it depends on how many strings are scanned per request. See the
/// `search_symbols` handler in `SWAMCPServer` for the canonical
/// `ContinuousClock.now.advanced(by:)` pattern.
///
/// This helper is the single source of truth for these guards; do not
/// re-implement them at call sites.
public enum SafeRegex {
    /// Maximum allowed UTF-8 length of a pattern, in bytes.
    public static let maxPatternLength = 512

    // MARK: Errors

    /// Reasons `compile` rejects a pattern.
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case tooLong(actual: Int, limit: Int)
        case antipattern(reason: String)
        case invalid(underlying: String)

        public var description: String {
            switch self {
            case .tooLong(let actual, let limit):
                return "Refusing regex pattern of \(actual) bytes (limit \(limit))."
            case .antipattern(let reason):
                return "Refusing regex pattern: \(reason)"
            case .invalid(let underlying):
                return "Invalid regex pattern: \(underlying)"
            }
        }
    }

    // MARK: Public API

    /// Compile a pattern after applying the length cap and the
    /// nested-quantifier prefilter. Returns the compiled regex on success or
    /// throws ``Failure`` describing the rejection.
    public static func compile(_ pattern: String) throws -> Regex<AnyRegexOutput> {
        try validate(pattern)
        do {
            return try Regex(pattern)
        } catch {
            throw Failure.invalid(underlying: error.localizedDescription)
        }
    }

    /// Validate a pattern without compiling it. Useful when the caller wants
    /// to short-circuit before any allocation, or wants to surface a
    /// length/antipattern rejection separately from a compilation error.
    public static func validate(_ pattern: String) throws {
        let byteCount = pattern.utf8.count
        if byteCount > maxPatternLength {
            throw Failure.tooLong(actual: byteCount, limit: maxPatternLength)
        }
        for antipattern in antipatterns where pattern.contains(antipattern) {
            throw Failure.antipattern(
                reason: "contains a nested-quantifier construct known for catastrophic backtracking.")
        }
    }

    // MARK: Internals

    /// Antipattern probes expressed with `RegexBuilder` so the prefilter is
    /// readable, typo-checked at compile time, and free of escape-sequence
    /// surprises. Each `Regex { ... }` is type-erased to
    /// `Regex<AnyRegexOutput>` at storage time so the array is homogeneous
    /// at the match site.
    ///
    /// `Regex` values are immutable after construction; the
    /// `nonisolated(unsafe)` qualifier is sound because the array is never
    /// mutated past the initialiser.
    ///
    /// Each entry catches a known ReDoS recipe:
    ///
    /// - **nestedQuantifierGroup**: `(...*...)` or `(...+...)` followed by
    ///   another `*`/`+` — the canonical "evil regex" structure
    ///   (`(a+)+`, `(.+)*`, etc.).
    /// - **catchAllRepetition**: literal `(.*)` followed by `*`/`+` —
    ///   `(.*)` already matches arbitrarily; quantifying it again is
    ///   gratuitous and pathological under most engines.
    nonisolated(unsafe) private static let antipatterns: [Regex<AnyRegexOutput>] = [
        Regex(
            Regex {
                "("
                ZeroOrMore(CharacterClass.anyOf(")").inverted)
                One(.anyOf("*+"))
                ZeroOrMore(CharacterClass.anyOf(")").inverted)
                ")"
                ZeroOrMore(.whitespace)
                One(.anyOf("*+"))
            }),
        Regex(
            Regex {
                "(.*)"
                ZeroOrMore(.whitespace)
                One(.anyOf("*+"))
            }),
    ]
}
