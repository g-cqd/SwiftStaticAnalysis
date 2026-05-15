//  SwiftFileParser.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - SwiftFileParser

/// Actor-based Swift file parser with AST caching.
///
/// Provides thread-safe parsing of Swift source files with automatic caching
/// to avoid re-parsing unchanged files. The cache is **bounded** (default
/// 256 entries) with LRU eviction: each `parse(_:)` call promotes the entry
/// to most-recently-used; once `cacheLimit` is exceeded the least-recently-
/// used entry is evicted. The bound matters for long-running MCP sessions
/// where unbounded retention of SwiftSyntax trees would leak memory.
public actor SwiftFileParser {
    // MARK: Lifecycle

    /// Initialise with an optional cache limit.
    ///
    /// - Parameter cacheLimit: Maximum number of cached parses to retain.
    ///   Each entry retains a full SwiftSyntax tree (often several MB).
    ///   Default 256 is safe for most CLI invocations and bounded enough
    ///   for long-running MCP servers.
    public init(cacheLimit: Int = 256) {
        let bounded = max(1, cacheLimit)
        self.cacheLimit = bounded
        self.cache = LRUDictionary(capacity: bounded)
    }

    // MARK: Public

    /// Get the number of cached files.
    public var cacheSize: Int {
        cache.count
    }

    /// Maximum number of cached parses to retain before LRU eviction.
    public let cacheLimit: Int

    // MARK: - Parsing

    /// Parse a single Swift file.
    ///
    /// - Parameter filePath: Absolute path to the Swift file.
    /// - Returns: The parsed source file syntax tree.
    /// - Throws: `AnalysisError` if the file cannot be read or parsed.
    public func parse(_ filePath: String) throws -> SourceFileSyntax {
        // Canonicalise the cache key so two different spellings (e.g.
        // /var/... vs /private/var/... on macOS) don't double-occupy the
        // cache.
        let key = PathUtilities.canonicalize(filePath)

        if let cached = cache.value(forKey: key) {
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
        let lineCount = source.utf8.lazy.count(where: { $0 == 0x0A }) + 1
        cache.setValue(
            CachedParse(
                syntax: syntax,
                modificationDate: modDate,
                lineCount: lineCount,
            ),
            forKey: key
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
        results.reserveCapacity(paths.count)

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
        cache.peek(forKey: filePath)?.lineCount
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
        source.utf8.lazy.count(where: { $0 == 0x0A }) + 1
    }

    // MARK: - Cache Management

    /// Invalidate the cache for a specific file.
    public func invalidateCache(for path: String) {
        cache.removeValue(forKey: PathUtilities.canonicalize(path))
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

    /// Cached parsed files. `LRUDictionary` (built on `OrderedDictionary`)
    /// is the canonical bounded-cache primitive — see
    /// `Sources/SwiftStaticAnalysisCore/Utilities/LRUDictionary.swift`.
    private var cache: LRUDictionary<String, CachedParse>

    private func readFile(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AnalysisError.fileNotFound(path)
        }

        do {
            return try SourceFileReader.readSource(at: path)
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
