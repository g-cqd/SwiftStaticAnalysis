//
//  TokenSequenceCache.swift
//  SwiftStaticAnalysis
//
//  Cache for token sequences to enable incremental duplication detection.
//

import Foundation
import SwiftStaticAnalysisCore

// MARK: - Cached Token Sequence

/// Token sequence data suitable for caching.
public struct CachedTokenSequence: Codable, Sendable {
    /// The file path.
    public let file: String

    /// Content hash for change detection.
    public let contentHash: UInt64

    /// Tokens.
    public let tokens: [CachedToken]

    /// Source lines for snippet extraction.
    public let sourceLines: [String]

    public struct CachedToken: Codable, Sendable {
        public let text: String
        public let kind: String
        public let line: Int
        public let column: Int
    }
}

// MARK: - Token Sequence Cache Data

/// Data structure for persisting token cache to disk.
struct TokenCacheData: Codable {
    static let formatVersion = 1

    let version: Int
    let sequences: [String: CachedTokenSequence]
    let timestamp: Date

    init(sequences: [String: CachedTokenSequence]) {
        self.version = Self.formatVersion
        self.sequences = sequences
        self.timestamp = Date()
    }
}

// MARK: - Token Sequence Cache

/// Actor-based cache for token sequences.
public actor TokenSequenceCache {

    /// Cached sequences by file path.
    private var sequences: [String: CachedTokenSequence] = [:]

    /// Cache file URL.
    private let cacheURL: URL?

    /// Whether cache has unsaved changes.
    private var isDirty: Bool = false

    // MARK: - Initialization

    public init(cacheDirectory: URL? = nil) {
        if let directory = cacheDirectory {
            self.cacheURL = directory.appendingPathComponent("token_cache.json")
        } else {
            self.cacheURL = nil
        }
    }

    // MARK: - Persistence

    /// Load cache from disk.
    public func load() async throws {
        guard let url = cacheURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let data = try Data(contentsOf: url)
        let cached = try JSONDecoder().decode(TokenCacheData.self, from: data)

        guard cached.version == TokenCacheData.formatVersion else {
            return
        }

        self.sequences = cached.sequences
        self.isDirty = false
    }

    /// Save cache to disk.
    public func save() async throws {
        guard isDirty, let url = cacheURL else { return }

        let cacheData = TokenCacheData(sequences: sequences)
        let encoder = JSONEncoder()
        let data = try encoder.encode(cacheData)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try data.write(to: url)
        isDirty = false
    }

    // MARK: - Cache Operations

    /// Get cached sequence for a file.
    ///
    /// - Parameters:
    ///   - file: File path.
    ///   - currentHash: Current content hash for validation.
    /// - Returns: Cached sequence if valid, nil otherwise.
    public func get(file: String, currentHash: UInt64) -> CachedTokenSequence? {
        guard let cached = sequences[file],
              cached.contentHash == currentHash else {
            return nil
        }
        return cached
    }

    /// Store a token sequence.
    ///
    /// - Parameter sequence: The sequence to cache.
    public func set(_ sequence: CachedTokenSequence) {
        sequences[sequence.file] = sequence
        isDirty = true
    }

    /// Remove cached sequence for a file.
    ///
    /// - Parameter file: File path.
    public func remove(file: String) {
        sequences.removeValue(forKey: file)
        isDirty = true
    }

    /// Clear all cached sequences.
    public func clear() {
        sequences.removeAll()
        isDirty = true
    }

    /// Check if cache has a valid entry for a file.
    ///
    /// - Parameters:
    ///   - file: File path.
    ///   - hash: Expected content hash.
    /// - Returns: True if cached and valid.
    public func hasValid(file: String, hash: UInt64) -> Bool {
        guard let cached = sequences[file] else { return false }
        return cached.contentHash == hash
    }

    /// Get all cached file paths.
    public func cachedFiles() -> Set<String> {
        Set(sequences.keys)
    }

    // MARK: - Statistics

    /// Cache statistics.
    public struct Statistics: Sendable {
        public let cachedFileCount: Int
        public let totalTokens: Int
    }

    public func statistics() -> Statistics {
        Statistics(
            cachedFileCount: sequences.count,
            totalTokens: sequences.values.reduce(0) { $0 + $1.tokens.count }
        )
    }
}

// MARK: - Token Sequence Conversion

extension TokenSequence {
    /// Convert to a cacheable format.
    public func toCached(contentHash: UInt64) -> CachedTokenSequence {
        CachedTokenSequence(
            file: file,
            contentHash: contentHash,
            tokens: tokens.map { token in
                CachedTokenSequence.CachedToken(
                    text: token.text,
                    kind: token.kind.rawValue,
                    line: token.line,
                    column: token.column
                )
            },
            sourceLines: sourceLines
        )
    }
}

extension CachedTokenSequence {
    /// Convert back to a TokenSequence.
    public func toTokenSequence() -> TokenSequence {
        TokenSequence(
            file: file,
            tokens: tokens.map { cached in
                TokenInfo(
                    kind: TokenKind(rawValue: cached.kind) ?? .identifier,
                    text: cached.text,
                    line: cached.line,
                    column: cached.column
                )
            },
            sourceLines: sourceLines
        )
    }
}
