//  TokenSequenceVisitor.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - TokenInfo

/// Represents a token with its location information.
public struct TokenInfo: Sendable, Hashable {
    // MARK: Lifecycle

    public init(kind: TokenKind, text: String, line: Int, column: Int) {
        self.kind = kind
        self.text = text
        self.line = line
        self.column = column
    }

    // MARK: Public

    /// The token kind.
    public let kind: TokenKind

    /// The token text.
    public let text: String

    /// Line number (1-based).
    public let line: Int

    /// Column number (1-based).
    public let column: Int
}

// MARK: - TokenKind

/// Simplified token kinds for clone detection.
public enum TokenKind: String, Sendable, Hashable {
    case keyword
    case identifier
    case literal
    case `operator`
    case punctuation
    case unknown
}

// MARK: - TokenSequenceProtocol

/// Protocol for token sequences used in stream building.
public protocol TokenSequenceProtocol: Sendable {
    /// The source file path.
    var file: String { get }
    /// Number of tokens in the sequence.
    var tokenCount: Int { get }
}

// MARK: - TokenSequence

/// A sequence of tokens from a source file.
public struct TokenSequence: Sendable, TokenSequenceProtocol {
    // MARK: Lifecycle

    public init(file: String, tokens: [TokenInfo], sourceLines: [String]) {
        self.file = file
        self.tokens = tokens
        self.sourceLines = sourceLines
    }

    // MARK: Public

    /// The source file path.
    public let file: String

    /// The tokens in order.
    public let tokens: [TokenInfo]

    /// Source lines for snippet extraction.
    public let sourceLines: [String]

    /// Number of tokens in the sequence.
    public var tokenCount: Int { tokens.count }

    /// Extract a code snippet for the given line range.
    public func snippet(startLine: Int, endLine: Int) -> String {
        let start = max(0, startLine - 1)
        let end = min(sourceLines.count, endLine)
        guard start < end else { return "" }
        return sourceLines[start..<end].joined(separator: "\n")
    }
}

// MARK: - TokenSequenceExtractor

/// Extracts tokens from Swift source files.
public struct TokenSequenceExtractor: Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// Extract token sequence from a parsed syntax tree.
    public func extract(from tree: SourceFileSyntax, file: String, source: String) -> TokenSequence {
        let sourceLines = source.components(separatedBy: .newlines)
        let converter = SourceLocationConverter(fileName: file, tree: tree)
        var tokens: [TokenInfo] = []

        for token in tree.tokens(viewMode: .sourceAccurate) {
            // Skip trivia (whitespace, comments)
            let kind = classifyToken(token)
            let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)

            tokens.append(
                TokenInfo(
                    kind: kind,
                    text: token.text,
                    line: location.line,
                    column: location.column,
                ))
        }

        return TokenSequence(file: file, tokens: tokens, sourceLines: sourceLines)
    }

    // MARK: Private

    // swa:ignore-duplicates - Token classification is structurally similar across parsers by design
    /// Classify a Swift syntax token into our simplified categories.
    private func classifyToken(_ token: TokenSyntax) -> TokenKind {
        switch token.tokenKind {
        // Keywords
        case .keyword:
            .keyword

        // Identifiers
        case .dollarIdentifier,
            .identifier:
            .identifier

        // Literals
        case .floatLiteral,
            .integerLiteral,
            .regexLiteralPattern,
            .regexSlash,
            .stringSegment:
            .literal

        // Operators
        case .arrow,
            .binaryOperator,
            .equal,
            .exclamationMark,
            .infixQuestionMark,
            .postfixOperator,
            .postfixQuestionMark,
            .prefixOperator:
            .operator

        // Punctuation
        case .atSign,
            .backslash,
            .backtick,
            .colon,
            .comma,
            .ellipsis,
            .leftAngle,
            .leftBrace,
            .leftParen,
            .leftSquare,
            .period,
            .pound,
            .rightAngle,
            .rightBrace,
            .rightParen,
            .rightSquare,
            .semicolon:
            .punctuation

        default:
            .unknown
        }
    }
}
