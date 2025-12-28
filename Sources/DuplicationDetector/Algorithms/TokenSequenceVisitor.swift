//
//  TokenSequenceVisitor.swift
//  SwiftStaticAnalysis
//
//  Extracts token sequences from Swift source code for clone detection.
//

import Foundation
import SwiftSyntax
import SwiftStaticAnalysisCore

// MARK: - Token Info

/// Represents a token with its location information.
public struct TokenInfo: Sendable, Hashable {
    /// The token kind.
    public let kind: TokenKind

    /// The token text.
    public let text: String

    /// Line number (1-based).
    public let line: Int

    /// Column number (1-based).
    public let column: Int

    public init(kind: TokenKind, text: String, line: Int, column: Int) {
        self.kind = kind
        self.text = text
        self.line = line
        self.column = column
    }
}

// MARK: - Token Kind

/// Simplified token kinds for clone detection.
public enum TokenKind: String, Sendable, Hashable {
    case keyword
    case identifier
    case literal
    case `operator`
    case punctuation
    case unknown
}

// MARK: - Token Sequence

/// A sequence of tokens from a source file.
public struct TokenSequence: Sendable {
    /// The source file path.
    public let file: String

    /// The tokens in order.
    public let tokens: [TokenInfo]

    /// Source lines for snippet extraction.
    public let sourceLines: [String]

    public init(file: String, tokens: [TokenInfo], sourceLines: [String]) {
        self.file = file
        self.tokens = tokens
        self.sourceLines = sourceLines
    }

    /// Extract a code snippet for the given line range.
    public func snippet(startLine: Int, endLine: Int) -> String {
        let start = max(0, startLine - 1)
        let end = min(sourceLines.count, endLine)
        guard start < end else { return "" }
        return sourceLines[start..<end].joined(separator: "\n")
    }
}

// MARK: - Token Sequence Extractor

/// Extracts tokens from Swift source files.
public struct TokenSequenceExtractor: Sendable {
    public init() {}

    /// Extract token sequence from a parsed syntax tree.
    public func extract(from tree: SourceFileSyntax, file: String, source: String) -> TokenSequence {
        let sourceLines = source.components(separatedBy: .newlines)
        let converter = SourceLocationConverter(fileName: file, tree: tree)
        var tokens: [TokenInfo] = []

        for token in tree.tokens(viewMode: .sourceAccurate) {
            // Skip trivia (whitespace, comments)
            let kind = classifyToken(token)
            let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)

            tokens.append(TokenInfo(
                kind: kind,
                text: token.text,
                line: location.line,
                column: location.column
            ))
        }

        return TokenSequence(file: file, tokens: tokens, sourceLines: sourceLines)
    }

    /// Classify a Swift syntax token into our simplified categories.
    private func classifyToken(_ token: TokenSyntax) -> TokenKind {
        switch token.tokenKind {
        // Keywords
        case .keyword:
            return .keyword

        // Identifiers
        case .identifier, .dollarIdentifier:
            return .identifier

        // Literals
        case .integerLiteral, .floatLiteral, .stringSegment,
             .regexLiteralPattern, .regexSlash:
            return .literal

        // Operators
        case .binaryOperator, .prefixOperator, .postfixOperator,
             .equal, .arrow, .exclamationMark,
             .infixQuestionMark, .postfixQuestionMark:
            return .operator

        // Punctuation
        case .leftParen, .rightParen, .leftBrace, .rightBrace,
             .leftSquare, .rightSquare, .leftAngle, .rightAngle,
             .comma, .colon, .semicolon, .period, .ellipsis,
             .atSign, .pound, .backslash, .backtick:
            return .punctuation

        default:
            return .unknown
        }
    }
}
