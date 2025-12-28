//
//  TokenNormalizer.swift
//  SwiftStaticAnalysis
//
//  Normalizes tokens for near-clone detection by replacing identifiers
//  and literals with placeholders.
//

import Foundation

// MARK: - Normalized Token

/// A normalized token for near-clone detection.
public struct NormalizedToken: Sendable, Hashable {
    /// The normalized representation.
    public let normalized: String

    /// The original token text.
    public let original: String

    /// The token kind.
    public let kind: TokenKind

    /// Line number.
    public let line: Int

    /// Column number.
    public let column: Int

    public init(normalized: String, original: String, kind: TokenKind, line: Int, column: Int) {
        self.normalized = normalized
        self.original = original
        self.kind = kind
        self.line = line
        self.column = column
    }
}

// MARK: - Normalized Sequence

/// A sequence of normalized tokens.
public struct NormalizedSequence: Sendable {
    /// The source file path.
    public let file: String

    /// The normalized tokens.
    public let tokens: [NormalizedToken]

    /// Source lines for snippet extraction.
    public let sourceLines: [String]

    public init(file: String, tokens: [NormalizedToken], sourceLines: [String]) {
        self.file = file
        self.tokens = tokens
        self.sourceLines = sourceLines
    }

    /// Get the normalized token texts for hashing.
    public var normalizedTexts: [String] {
        tokens.map { $0.normalized }
    }

    /// Extract a code snippet for the given line range.
    public func snippet(startLine: Int, endLine: Int) -> String {
        let start = max(0, startLine - 1)
        let end = min(sourceLines.count, endLine)
        guard start < end else { return "" }
        return sourceLines[start..<end].joined(separator: "\n")
    }
}

// MARK: - Token Normalizer

/// Normalizes tokens for near-clone detection.
public struct TokenNormalizer: Sendable {
    /// Placeholder for identifiers.
    public static let identifierPlaceholder = "$ID"

    /// Placeholder for string literals.
    public static let stringPlaceholder = "$STR"

    /// Placeholder for numeric literals.
    public static let numberPlaceholder = "$NUM"

    /// Placeholder for closure shorthand parameters ($0, $1, etc.).
    public static let shorthandParamPlaceholder = "$PARAM"

    /// Whether to normalize identifiers.
    public var normalizeIdentifiers: Bool

    /// Whether to normalize literals.
    public var normalizeLiterals: Bool

    /// Whether to normalize closure shorthand parameters.
    public var normalizeClosureParams: Bool

    /// Identifiers to preserve (not normalize).
    public var preservedIdentifiers: Set<String>

    public init(
        normalizeIdentifiers: Bool = true,
        normalizeLiterals: Bool = true,
        normalizeClosureParams: Bool = true,
        preservedIdentifiers: Set<String> = []
    ) {
        self.normalizeIdentifiers = normalizeIdentifiers
        self.normalizeLiterals = normalizeLiterals
        self.normalizeClosureParams = normalizeClosureParams
        self.preservedIdentifiers = preservedIdentifiers
    }

    /// Default normalizer with common Swift keywords preserved.
    public static let `default` = TokenNormalizer(
        preservedIdentifiers: [
            // Common type names
            "String", "Int", "Double", "Float", "Bool", "Array", "Dictionary",
            "Set", "Optional", "Result", "Error", "Void", "Any", "AnyObject",
            // Common identifiers
            "self", "Self", "super", "nil", "true", "false",
            // Common function names
            "print", "fatalError", "precondition", "assert",
        ]
    )

    /// Normalize a token sequence.
    public func normalize(_ sequence: TokenSequence) -> NormalizedSequence {
        let normalizedTokens = sequence.tokens.map { token -> NormalizedToken in
            let normalized = normalizeToken(token)
            return NormalizedToken(
                normalized: normalized,
                original: token.text,
                kind: token.kind,
                line: token.line,
                column: token.column
            )
        }

        return NormalizedSequence(
            file: sequence.file,
            tokens: normalizedTokens,
            sourceLines: sequence.sourceLines
        )
    }

    /// Normalize a single token.
    private func normalizeToken(_ token: TokenInfo) -> String {
        switch token.kind {
        case .identifier:
            // Check for closure shorthand parameters ($0, $1, etc.)
            if normalizeClosureParams && isShorthandParameter(token.text) {
                return Self.shorthandParamPlaceholder
            }
            if normalizeIdentifiers && !preservedIdentifiers.contains(token.text) {
                return Self.identifierPlaceholder
            }
            return token.text

        case .literal:
            if normalizeLiterals {
                return classifyLiteral(token.text)
            }
            return token.text

        case .keyword, .operator, .punctuation, .unknown:
            return token.text
        }
    }

    /// Check if an identifier is a closure shorthand parameter.
    private func isShorthandParameter(_ text: String) -> Bool {
        guard text.hasPrefix("$") else { return false }
        let rest = text.dropFirst()
        return rest.allSatisfy { $0.isNumber }
    }

    /// Classify a literal and return appropriate placeholder.
    private func classifyLiteral(_ text: String) -> String {
        // Check if it's a string literal
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            return Self.stringPlaceholder
        }

        // Check if it's a number
        if text.first?.isNumber == true || text.hasPrefix("-") || text.hasPrefix(".") {
            return Self.numberPlaceholder
        }

        return Self.stringPlaceholder
    }
}
