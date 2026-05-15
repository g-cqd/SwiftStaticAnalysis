//  TokenJaccard.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - TokenJaccard

/// Cheap token-set Jaccard similarity for Swift source strings. Used by
/// `EmbeddingCloneDiscovery` to filter out cosine-positive but lexically
/// disjoint candidate pairs — the "shape-true, intent-false" failure
/// mode that CodeBERT and high-threshold contrastive models exhibit
/// on Swift code.
///
/// The tokenization is regex-light: split on non-identifier characters,
/// lowercase, drop tokens that are pure Swift syntax noise (keywords like
/// `let`, `var`, `func`, `return`, `if`, `else`, `guard`, `throws`, etc.).
/// What remains is the snippet's identifier + literal vocabulary. Two
/// snippets that share most of their identifiers have high Jaccard; two
/// snippets that share only structural keywords have low Jaccard.
///
/// Not a replacement for full SwiftSyntax tokenization — `ZeroCopyParser`
/// is the canonical path for that. This helper is fast (one regex pass)
/// and stateless, by design.
public enum TokenJaccard {
    /// Stop-words filtered out before Jaccard. Swift control-flow + type
    /// keywords plus a handful of universal noise tokens. The list is
    /// deliberately small; over-filtering hides real signal.
    public static let stopWords: Set<String> = [
        "let", "var", "func", "return", "if", "else", "guard", "throws",
        "try", "await", "async", "private", "public", "internal", "fileprivate",
        "package", "static", "final", "class", "struct", "enum", "protocol",
        "actor", "extension", "case", "default", "where", "in", "for", "while",
        "do", "switch", "break", "continue", "self", "init", "deinit",
        "true", "false", "nil", "as", "is", "throw",
    ]

    /// Tokenize source code by identifier boundary. Returns a `Set<String>`
    /// of lowercased identifiers, with `stopWords` removed.
    public static func tokenSet(_ source: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        for scalar in source.unicodeScalars {
            if scalar.isLetter || scalar.isDigit || scalar == "_" {
                current.append(Character(scalar))
            } else {
                if !current.isEmpty {
                    let lower = current.lowercased()
                    if !stopWords.contains(lower) {
                        result.insert(lower)
                    }
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            let lower = current.lowercased()
            if !stopWords.contains(lower) {
                result.insert(lower)
            }
        }
        return result
    }

    /// Jaccard similarity (intersection / union) between the two snippets'
    /// token sets. Returns `0.0` when both sets are empty.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let setA = tokenSet(a)
        let setB = tokenSet(b)
        if setA.isEmpty, setB.isEmpty { return 0 }
        let intersection = Double(setA.intersection(setB).count)
        let union = Double(setA.union(setB).count)
        return union == 0 ? 0 : intersection / union
    }

    /// Pair-level fused score combining cosine + Jaccard. The weighted
    /// mean is a robust default; cosine alone misranks shape-true
    /// false positives. Callers may override the weight.
    public static func fused(cosine: Double, jaccard: Double, cosineWeight: Double = 0.6)
        -> Double
    {
        let cw = min(max(cosineWeight, 0), 1)
        return cw * cosine + (1 - cw) * jaccard
    }
}

private extension Unicode.Scalar {
    var isLetter: Bool {
        (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
            || properties.isAlphabetic
    }
    var isDigit: Bool {
        value >= 0x30 && value <= 0x39
    }
}
