//
//  SwiftFileParser.swift
//  SwiftStaticAnalysis
//

import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - SwiftFileParser

/// Actor-based Swift file parser with AST caching.
///
/// Provides thread-safe parsing of Swift source files with
/// automatic caching to avoid re-parsing unchanged files.
public actor SwiftFileParser {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// Get the number of cached files.
    public var cacheSize: Int {
        cache.count
    }

    // MARK: - Parsing

    /// Parse a single Swift file.
    ///
    /// - Parameter filePath: Absolute path to the Swift file.
    /// - Returns: The parsed source file syntax tree.
    /// - Throws: `AnalysisError` if the file cannot be read or parsed.
    public func parse(_ filePath: String) throws -> SourceFileSyntax {
        // Check if we have a valid cached version
        if let cached = cache[filePath] {
            let currentModDate = try fileModificationDate(filePath)
            if cached.modificationDate >= currentModDate {
                return cached.syntax
            }
        }

        // Parse the file
        let source = try readFile(filePath)
        let syntax = Parser.parse(source: source)

        // Cache the result
        let modDate = try fileModificationDate(filePath)
        let lineCount = source.components(separatedBy: "\n").count
        cache[filePath] = CachedParse(
            syntax: syntax,
            modificationDate: modDate,
            lineCount: lineCount,
        )

        return syntax
    }

    /// Parse multiple Swift files concurrently.
    ///
    /// - Parameter paths: Array of file paths to parse.
    /// - Returns: Dictionary mapping file paths to their syntax trees.
    /// - Throws: `AnalysisError` if any file cannot be parsed.
    public func parseAll(_ paths: [String]) async throws -> [String: SourceFileSyntax] {
        var results: [String: SourceFileSyntax] = [:]

        // Parse files - note: we're already in an actor so this is sequential
        // For true parallelism, callers should use TaskGroup
        for path in paths {
            results[path] = try parse(path)
        }

        return results
    }

    /// Get the line count for a cached file.
    ///
    /// - Parameter filePath: Path to the file.
    /// - Returns: Line count if cached, nil otherwise.
    public func lineCount(for filePath: String) -> Int? {
        cache[filePath]?.lineCount
    }

    // MARK: - Source String Parsing

    /// Parse Swift source code from a string.
    ///
    /// - Parameter source: Swift source code string.
    /// - Returns: The parsed source file syntax tree.
    public func parse(source: String) throws -> SourceFileSyntax {
        Parser.parse(source: source)
    }

    /// Get the line count for a source string.
    ///
    /// - Parameter source: Swift source code string.
    /// - Returns: Number of lines in the source.
    public func lineCount(source: String) throws -> Int {
        source.components(separatedBy: "\n").count
    }

    // MARK: - Cache Management

    /// Invalidate the cache for a specific file.
    public func invalidateCache(for path: String) {
        cache.removeValue(forKey: path)
    }

    /// Clear the entire cache.
    public func clearCache() {
        cache.removeAll()
    }

    // MARK: Private

    /// Cache entry with timestamp for invalidation.
    private struct CachedParse: Sendable {
        let syntax: SourceFileSyntax
        let modificationDate: Date
        let lineCount: Int
    }

    /// Cached parsed files.
    private var cache: [String: CachedParse] = [:]

    // MARK: - Private Helpers

    private func readFile(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            throw AnalysisError.fileNotFound(path)
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw AnalysisError.ioError("Failed to read \(path): \(error.localizedDescription)")
        }
    }

    private func fileModificationDate(_ path: String) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return attributes[.modificationDate] as? Date ?? Date.distantPast
    }
}

// MARK: - Syntax Position Extensions

extension AbsolutePosition {
    /// Convert to SourceLocation using a converter.
    public func toSourceLocation(
        using converter: SourceLocationConverter,
        file: String,
    ) -> SourceLocation {
        let location = converter.location(for: self)
        return SourceLocation(
            file: file,
            line: location.line,
            column: location.column,
            offset: utf8Offset,
        )
    }
}

extension SyntaxProtocol {
    /// Get the source range for this syntax node.
    public func sourceRange(
        using converter: SourceLocationConverter,
        file: String,
    ) -> SourceRange {
        let start = position.toSourceLocation(using: converter, file: file)
        let end = endPosition.toSourceLocation(using: converter, file: file)
        return SourceRange(start: start, end: end)
    }
}
