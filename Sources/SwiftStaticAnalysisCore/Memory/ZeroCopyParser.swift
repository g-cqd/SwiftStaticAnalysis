//
//  ZeroCopyParser.swift
//  SwiftStaticAnalysis
//
//  Zero-copy Swift file parsing using memory-mapped I/O and SoA token storage.
//
//  This module integrates:
//  - MemoryMappedFile for zero-copy file access
//  - SoATokenStorage for cache-efficient token storage
//  - Arena allocation for temporary data
//

import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Zero-Copy Parser Configuration

/// Configuration for zero-copy parsing.
public struct ZeroCopyParserConfiguration: Sendable {
    /// Minimum file size to use memory mapping (smaller files use regular I/O).
    public let mmapThreshold: Int

    /// Arena block size for temporary allocations.
    public let arenaBlockSize: Int

    /// Whether to pre-compute line ranges.
    public let computeLineRanges: Bool

    public init(
        mmapThreshold: Int = 4096,
        arenaBlockSize: Int = 65536,
        computeLineRanges: Bool = true
    ) {
        self.mmapThreshold = mmapThreshold
        self.arenaBlockSize = arenaBlockSize
        self.computeLineRanges = computeLineRanges
    }

    public static let `default` = ZeroCopyParserConfiguration()

    /// High-performance configuration for large codebases.
    public static let highPerformance = ZeroCopyParserConfiguration(
        mmapThreshold: 1024,
        arenaBlockSize: 262144,
        computeLineRanges: true
    )
}

// MARK: - Zero-Copy Parsed File

/// Result of parsing a file with zero-copy methods.
public struct ZeroCopyParsedFile: Sendable {
    /// Path to the source file.
    public let path: String

    /// Memory-mapped source (nil if file was too small for mmap).
    public let mappedSource: MemoryMappedFile?

    /// Source string (used if file was too small for mmap).
    public let sourceString: String?

    /// Tokens in SoA format.
    public let tokens: SoATokenStorage

    /// Syntax tree (optional, may be nil if only token extraction was needed).
    public let syntaxTree: SourceFileSyntax?

    /// Line ranges: (offset, length) for each line.
    public let lineRanges: [(offset: Int, length: Int)]?

    /// Number of lines in the file.
    public var lineCount: Int {
        lineRanges?.count ?? 0
    }

    /// File size in bytes.
    public var size: Int {
        mappedSource?.size ?? (sourceString?.utf8.count ?? 0)
    }

    /// Get source text (creates string if memory-mapped).
    public var source: String {
        if let s = sourceString {
            return s
        }
        return mappedSource?.readAsString() ?? ""
    }

    /// Get token text at index.
    public func tokenText(at index: Int) -> String? {
        if let mapped = mappedSource {
            return tokens.text(at: index, from: mapped)
        } else if let source = sourceString {
            let offset = tokens.offset(at: index)
            let length = tokens.length(at: index)
            let start = source.utf8.index(source.utf8.startIndex, offsetBy: offset)
            let end = source.utf8.index(start, offsetBy: length)
            return String(source.utf8[start..<end])
        }
        return nil
    }

    /// Get a code snippet for a line range.
    public func snippet(startLine: Int, endLine: Int) -> String {
        guard let ranges = lineRanges else { return "" }
        let start = max(0, startLine - 1)
        let end = min(ranges.count, endLine)
        guard start < end else { return "" }

        let startOffset = ranges[start].offset
        let lastRange = ranges[end - 1]
        let length = lastRange.offset + lastRange.length - startOffset

        if let mapped = mappedSource {
            return mapped.slice(offset: startOffset, length: length).asString() ?? ""
        } else if let source = sourceString {
            let startIdx = source.utf8.index(source.utf8.startIndex, offsetBy: startOffset)
            let endIdx = source.utf8.index(startIdx, offsetBy: length)
            return String(source.utf8[startIdx..<endIdx]) ?? ""
        }
        return ""
    }
}

// MARK: - Zero-Copy Parser

/// Parser that uses memory-mapped I/O and SoA storage for optimal performance.
public actor ZeroCopyParser {
    /// Configuration.
    public let configuration: ZeroCopyParserConfiguration

    /// Cache of parsed files.
    private var cache: [String: CachedZeroCopyParse] = [:]

    /// Cache entry.
    private struct CachedZeroCopyParse {
        let parsedFile: ZeroCopyParsedFile
        let modificationDate: Date
    }

    public init(configuration: ZeroCopyParserConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Parsing

    /// Parse a Swift file using zero-copy methods.
    ///
    /// - Parameter path: Path to the Swift file.
    /// - Returns: Parsed file with tokens and optional syntax tree.
    public func parse(_ path: String) throws -> ZeroCopyParsedFile {
        // Check cache
        if let cached = cache[path] {
            let currentModDate = try fileModificationDate(path)
            if cached.modificationDate >= currentModDate {
                return cached.parsedFile
            }
        }

        // Get file size
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attrs[.size] as? Int) ?? 0

        let parsedFile: ZeroCopyParsedFile

        if fileSize >= configuration.mmapThreshold {
            // Use memory-mapped I/O
            parsedFile = try parseMemoryMapped(path: path)
        } else {
            // Use regular I/O for small files
            parsedFile = try parseRegular(path: path)
        }

        // Cache result
        let modDate = try fileModificationDate(path)
        cache[path] = CachedZeroCopyParse(
            parsedFile: parsedFile,
            modificationDate: modDate
        )

        return parsedFile
    }

    /// Parse multiple files.
    public func parseAll(_ paths: [String]) async throws -> [ZeroCopyParsedFile] {
        var results: [ZeroCopyParsedFile] = []
        for path in paths {
            results.append(try parse(path))
        }
        return results
    }

    /// Parse and extract only tokens (no syntax tree).
    public func extractTokens(_ path: String) throws -> SoATokenStorage {
        try parse(path).tokens
    }

    // MARK: - Private Implementation

    private func parseMemoryMapped(path: String) throws -> ZeroCopyParsedFile {
        let mapped = try MemoryMappedFile(path: path)
        let source = mapped.readAsString() ?? ""

        // Parse syntax tree
        let syntax = Parser.parse(source: source)

        // Extract tokens to SoA storage
        let tokens = extractTokensToSoA(from: syntax, source: source)

        // Compute line ranges
        let lineRanges = configuration.computeLineRanges ? mapped.findLineRanges() : nil

        return ZeroCopyParsedFile(
            path: path,
            mappedSource: mapped,
            sourceString: nil,
            tokens: tokens,
            syntaxTree: syntax,
            lineRanges: lineRanges
        )
    }

    private func parseRegular(path: String) throws -> ZeroCopyParsedFile {
        let source = try String(contentsOfFile: path, encoding: .utf8)

        // Parse syntax tree
        let syntax = Parser.parse(source: source)

        // Extract tokens to SoA storage
        let tokens = extractTokensToSoA(from: syntax, source: source)

        // Compute line ranges
        var lineRanges: [(Int, Int)]? = nil
        if configuration.computeLineRanges {
            lineRanges = computeLineRanges(from: source)
        }

        return ZeroCopyParsedFile(
            path: path,
            mappedSource: nil,
            sourceString: source,
            tokens: tokens,
            syntaxTree: syntax,
            lineRanges: lineRanges
        )
    }

    private func extractTokensToSoA(from tree: SourceFileSyntax, source: String) -> SoATokenStorage {
        var storage = SoATokenStorage()
        let converter = SourceLocationConverter(fileName: "", tree: tree)

        for token in tree.tokens(viewMode: .sourceAccurate) {
            let kind = classifyToken(token)
            let position = token.positionAfterSkippingLeadingTrivia
            let location = converter.location(for: position)

            storage.append(
                kind: kind,
                offset: position.utf8Offset,
                length: token.text.utf8.count,
                line: location.line,
                column: location.column
            )
        }

        return storage
    }

    private func classifyToken(_ token: TokenSyntax) -> TokenKindByte {
        switch token.tokenKind {
        case .keyword:
            return .keyword
        case .identifier, .dollarIdentifier:
            return .identifier
        case .integerLiteral, .floatLiteral, .stringSegment,
             .regexLiteralPattern, .regexSlash:
            return .literal
        case .binaryOperator, .prefixOperator, .postfixOperator,
             .equal, .arrow, .exclamationMark,
             .infixQuestionMark, .postfixQuestionMark:
            return .operator
        case .leftParen, .rightParen, .leftBrace, .rightBrace,
             .leftSquare, .rightSquare, .leftAngle, .rightAngle,
             .comma, .colon, .semicolon, .period, .ellipsis,
             .atSign, .pound, .backslash, .backtick:
            return .punctuation
        default:
            return .unknown
        }
    }

    private func computeLineRanges(from source: String) -> [(Int, Int)] {
        var ranges: [(Int, Int)] = []
        var lineStart = 0
        let bytes = Array(source.utf8)

        for (i, byte) in bytes.enumerated() {
            if byte == 0x0A { // '\n'
                ranges.append((lineStart, i - lineStart))
                lineStart = i + 1
            }
        }

        if lineStart < bytes.count {
            ranges.append((lineStart, bytes.count - lineStart))
        }

        return ranges
    }

    private func fileModificationDate(_ path: String) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.modificationDate] as? Date) ?? Date.distantPast
    }

    // MARK: - Cache Management

    /// Clear the parse cache.
    public func clearCache() {
        cache.removeAll()
    }

    /// Invalidate cache for a specific file.
    public func invalidateCache(for path: String) {
        cache.removeValue(forKey: path)
    }

    /// Number of cached files.
    public var cacheSize: Int {
        cache.count
    }
}

// MARK: - Batch Token Extraction

/// Batch extractor for efficient multi-file token extraction.
public struct BatchTokenExtractor: Sendable {
    /// Configuration.
    public let configuration: ZeroCopyParserConfiguration

    public init(configuration: ZeroCopyParserConfiguration = .default) {
        self.configuration = configuration
    }

    /// Extract tokens from multiple files into a single MultiFileSoAStorage.
    ///
    /// - Parameter paths: File paths to process.
    /// - Returns: Combined storage with all tokens and file boundaries.
    public func extract(from paths: [String]) async throws -> MultiFileSoAStorage {
        let parser = ZeroCopyParser(configuration: configuration)
        var multiStorage = MultiFileSoAStorage()

        for path in paths {
            let parsed = try await parser.parse(path)
            multiStorage.addFile(path: path, tokens: parsed.tokens)
        }

        return multiStorage
    }

    /// Extract tokens using parallel processing.
    ///
    /// - Parameters:
    ///   - paths: File paths to process.
    ///   - maxConcurrency: Maximum number of concurrent operations.
    /// - Returns: Combined storage with all tokens.
    public func extractParallel(
        from paths: [String],
        maxConcurrency: Int = 8
    ) async throws -> MultiFileSoAStorage {
        // Parse files in parallel with concurrency limiting
        let parsed = try await withThrowingTaskGroup(of: (String, SoATokenStorage).self) { group in
            let parser = ZeroCopyParser(configuration: configuration)
            var results: [(String, SoATokenStorage)] = []
            var iterator = paths.makeIterator()
            var inFlight = 0

            // Start initial batch up to maxConcurrency
            while inFlight < maxConcurrency, let path = iterator.next() {
                group.addTask {
                    let file = try await parser.parse(path)
                    return (path, file.tokens)
                }
                inFlight += 1
            }

            // As tasks complete, start new ones
            while let result = try await group.next() {
                results.append(result)
                inFlight -= 1

                if let path = iterator.next() {
                    group.addTask {
                        let file = try await parser.parse(path)
                        return (path, file.tokens)
                    }
                    inFlight += 1
                }
            }

            return results
        }

        // Combine into multi-file storage (sequential to maintain order)
        var multiStorage = MultiFileSoAStorage()
        for (path, tokens) in parsed.sorted(by: { $0.0 < $1.0 }) {
            multiStorage.addFile(path: path, tokens: tokens)
        }

        return multiStorage
    }
}
