//  RegexLiteralExtractor.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - RegexLiteralExtractor

/// Best-effort extraction of literal substrings from a regex pattern.
/// A literal substring is a maximal run of characters that the regex
/// engine will match byte-for-byte — i.e. no metacharacters
/// (`. * + ? ( ) [ ] { } | \ ^ $`) and not inside a group, character
/// class, or backreference scope.
///
/// The extracted literals are used by `TrigramIndex` to narrow the
/// candidate set for `IndexStoreResolver.resolveByRegex`. Patterns
/// that contain no extractable literals of length ≥ 3 (e.g. pure
/// character classes, alternation-heavy expressions, or short
/// regexes) yield an empty set and the caller falls back to a linear
/// scan over all definitions.
///
/// This is a conservative parser: when in doubt, drop the literal.
/// False negatives (missing a literal that's actually safe to
/// extract) cost recall opportunities but never correctness. False
/// positives (extracting a "literal" that the regex would treat
/// differently) would silently drop matches and are correctness
/// bugs — so the parser refuses anything ambiguous.
enum RegexLiteralExtractor {
    /// Extract the set of literal substrings of length ≥ 3 from the
    /// top-level (un-grouped, un-quantified, un-alternated) segments
    /// of `pattern`.
    ///
    /// Returns an empty set when no extractable literals exist; this
    /// is the signal to the caller that the trigram index cannot
    /// help and a linear scan is required.
    static func literalSubstrings(in pattern: String) -> [String] {
        var literals: [String] = []
        var current = String.UnicodeScalarView()
        var scalars = pattern.unicodeScalars.makeIterator()
        // Group depth: when > 0, we're inside `(...)` and the literals
        // we collect are conditional on the group's quantifier. We
        // drop them rather than complicate the analysis. Same for
        // character-class depth.
        var groupDepth = 0
        var classDepth = 0
        // Whether the next scalar is escaped by a backslash. Swift
        // regex literal escapes (`\d`, `\s`, etc.) are dropped from
        // the literal stream.
        var escaped = false

        @discardableResult
        func flush() -> Bool {
            if current.count >= 3 {
                literals.append(String(current))
            }
            current.removeAll(keepingCapacity: true)
            return true
        }

        while let scalar = scalars.next() {
            if escaped {
                escaped = false
                // Escaped scalars: drop the run. We can't tell from
                // here whether `\b` is a word boundary (zero-width)
                // or `\B`; safest to discard the partial literal.
                flush()
                continue
            }
            switch scalar {
            case "\\":
                escaped = true
                flush()
            case "(":
                groupDepth += 1
                flush()
            case ")":
                groupDepth = max(0, groupDepth - 1)
                flush()
            case "[":
                classDepth += 1
                flush()
            case "]":
                classDepth = max(0, classDepth - 1)
                flush()
            case ".", "*", "+", "?", "{", "}", "|", "^", "$":
                // Metacharacter or quantifier boundary — flush and
                // skip. We also drop the trailing scalar of the
                // current literal because `abc*` only guarantees
                // `ab`, not `abc`: the `c` is governed by `*`.
                if scalar == "*" || scalar == "+" || scalar == "?" || scalar == "{" {
                    if !current.isEmpty {
                        _ = current.popLast()
                    }
                }
                flush()
            default:
                if groupDepth == 0, classDepth == 0 {
                    current.append(scalar)
                }
            }
        }
        flush()
        return literals
    }

    /// Convenience: the union of all trigrams from every extracted
    /// literal of length ≥ 3. Returns `nil` when no literal segments
    /// are long enough to contribute a trigram — the caller's signal
    /// to skip the trigram index entirely.
    static func requiredTrigrams(in pattern: String) -> Set<String>? {
        let literals = literalSubstrings(in: pattern)
        guard !literals.isEmpty else { return nil }
        var trigrams = Set<String>()
        for literal in literals {
            for trigram in TrigramIndex.trigrams(of: literal) {
                trigrams.insert(trigram)
            }
        }
        return trigrams.isEmpty ? nil : trigrams
    }
}
