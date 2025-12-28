//
//  ShingleGenerator.swift
//  SwiftStaticAnalysis
//
//  Generates shingles (n-grams) from token sequences for MinHash computation.
//  Shingles capture local structure while being robust to insertions/deletions.
//

import Foundation

// MARK: - Shingle

/// A shingle (n-gram) of tokens with its hash.
public struct Shingle: Sendable, Hashable {
    /// Hash value of the shingle.
    public let hash: UInt64

    /// Starting position in the token sequence.
    public let position: Int

    /// The tokens comprising this shingle (for debugging).
    public let tokens: [String]

    public init(hash: UInt64, position: Int, tokens: [String]) {
        self.hash = hash
        self.position = position
        self.tokens = tokens
    }
}

// MARK: - Shingled Document

/// A document (code block) represented as a set of shingles.
public struct ShingledDocument: Sendable {
    /// Source file path.
    public let file: String

    /// Starting line in the file.
    public let startLine: Int

    /// Ending line in the file.
    public let endLine: Int

    /// Token count.
    public let tokenCount: Int

    /// Set of shingle hashes (for MinHash).
    public let shingleHashes: Set<UInt64>

    /// All shingles with position info (for alignment).
    public let shingles: [Shingle]

    /// Unique identifier for this document.
    public let id: Int

    public init(
        file: String,
        startLine: Int,
        endLine: Int,
        tokenCount: Int,
        shingleHashes: Set<UInt64>,
        shingles: [Shingle],
        id: Int
    ) {
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.tokenCount = tokenCount
        self.shingleHashes = shingleHashes
        self.shingles = shingles
        self.id = id
    }
}

// MARK: - Shingle Generator

/// Generates shingles from token sequences.
public struct ShingleGenerator: Sendable {
    /// Size of each shingle (number of tokens).
    public let shingleSize: Int

    /// Whether to normalize identifiers/literals.
    public let normalize: Bool

    public init(shingleSize: Int = 5, normalize: Bool = true) {
        self.shingleSize = max(1, shingleSize)
        self.normalize = normalize
    }

    /// Generate shingles from a token sequence.
    ///
    /// - Parameters:
    ///   - tokens: The token texts.
    ///   - kinds: The token kinds (for normalization).
    /// - Returns: Array of shingles.
    public func generate(tokens: [String], kinds: [TokenKind]? = nil) -> [Shingle] {
        guard tokens.count >= shingleSize else { return [] }

        let normalizedTokens: [String]
        if normalize, let kinds = kinds {
            normalizedTokens = normalizeTokens(tokens, kinds: kinds)
        } else {
            normalizedTokens = tokens
        }

        var shingles: [Shingle] = []
        let maxStart = normalizedTokens.count - shingleSize

        for i in 0...maxStart {
            let shingleTokens = Array(normalizedTokens[i..<(i + shingleSize)])
            let hash = computeShingleHash(shingleTokens)
            shingles.append(Shingle(hash: hash, position: i, tokens: shingleTokens))
        }

        return shingles
    }

    /// Generate shingles from a TokenSequence.
    ///
    /// - Parameter sequence: The token sequence.
    /// - Returns: Shingled document.
    public func generateDocument(
        from sequence: TokenSequence,
        id: Int
    ) -> ShingledDocument {
        let tokens = sequence.tokens.map { $0.text }
        let kinds = sequence.tokens.map { $0.kind }
        let shingles = generate(tokens: tokens, kinds: kinds)

        let startLine = sequence.tokens.first?.line ?? 1
        let endLine = sequence.tokens.last?.line ?? startLine

        return ShingledDocument(
            file: sequence.file,
            startLine: startLine,
            endLine: endLine,
            tokenCount: sequence.tokens.count,
            shingleHashes: Set(shingles.map { $0.hash }),
            shingles: shingles,
            id: id
        )
    }

    /// Generate shingled documents from code blocks within a file.
    ///
    /// This breaks the file into logical blocks (functions, classes) for comparison.
    ///
    /// - Parameters:
    ///   - sequence: The full file token sequence.
    ///   - blockSize: Minimum tokens per block.
    ///   - startId: Starting ID for documents.
    /// - Returns: Array of shingled documents.
    public func generateBlockDocuments(
        from sequence: TokenSequence,
        blockSize: Int,
        startId: Int
    ) -> [ShingledDocument] {
        guard sequence.tokens.count >= blockSize else { return [] }

        var documents: [ShingledDocument] = []
        var currentId = startId

        // Use sliding window approach for overlapping blocks
        let tokens = sequence.tokens.map { $0.text }
        let kinds = sequence.tokens.map { $0.kind }
        let stride = max(1, blockSize / 2) // 50% overlap

        var i = 0
        while i + blockSize <= sequence.tokens.count {
            let blockTokens = Array(tokens[i..<(i + blockSize)])
            let blockKinds = Array(kinds[i..<(i + blockSize)])
            let shingles = generate(tokens: blockTokens, kinds: blockKinds)

            let startLine = sequence.tokens[i].line
            let endLine = sequence.tokens[i + blockSize - 1].line

            documents.append(ShingledDocument(
                file: sequence.file,
                startLine: startLine,
                endLine: endLine,
                tokenCount: blockSize,
                shingleHashes: Set(shingles.map { $0.hash }),
                shingles: shingles,
                id: currentId
            ))

            currentId += 1
            i += stride
        }

        return documents
    }

    // MARK: - Private Helpers

    /// Normalize tokens by replacing identifiers and literals with placeholders.
    private func normalizeTokens(_ tokens: [String], kinds: [TokenKind]) -> [String] {
        var result: [String] = []
        var identifierMap: [String: String] = [:]
        var literalMap: [String: String] = [:]
        var identifierCount = 0
        var literalCount = 0

        for (token, kind) in zip(tokens, kinds) {
            switch kind {
            case .identifier:
                if let normalized = identifierMap[token] {
                    result.append(normalized)
                } else {
                    let normalized = "$ID\(identifierCount)"
                    identifierMap[token] = normalized
                    identifierCount += 1
                    result.append(normalized)
                }

            case .literal:
                if let normalized = literalMap[token] {
                    result.append(normalized)
                } else {
                    let normalized = "$LIT\(literalCount)"
                    literalMap[token] = normalized
                    literalCount += 1
                    result.append(normalized)
                }

            default:
                result.append(token)
            }
        }

        return result
    }

    /// Compute hash for a shingle using FNV-1a.
    private func computeShingleHash(_ tokens: [String]) -> UInt64 {
        // FNV-1a 64-bit hash
        var hash: UInt64 = 14695981039346656037 // FNV offset basis
        let prime: UInt64 = 1099511628211 // FNV prime

        for token in tokens {
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            // Separator between tokens
            hash ^= 0xFF
            hash = hash &* prime
        }

        return hash
    }
}

// MARK: - Character Shingles

extension ShingleGenerator {
    /// Generate character-level shingles (k-grams of characters).
    ///
    /// This is useful for detecting clones with minor textual differences.
    ///
    /// - Parameters:
    ///   - text: The source text.
    ///   - k: The shingle size in characters.
    /// - Returns: Set of shingle hashes.
    public func generateCharacterShingles(from text: String, k: Int = 9) -> Set<UInt64> {
        let chars = Array(text)
        guard chars.count >= k else { return [] }

        var hashes = Set<UInt64>()

        for i in 0...(chars.count - k) {
            let shingle = String(chars[i..<(i + k)])
            hashes.insert(computeStringHash(shingle))
        }

        return hashes
    }

    /// Compute hash for a string.
    private func computeStringHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211

        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }

        return hash
    }
}
