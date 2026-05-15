//  ShingleGenerator.swift
//  SwiftStaticAnalysis
//  MIT License

import Algorithms
import Foundation
import SwiftStaticAnalysisCore

// MARK: - Shingle

/// A shingle (n-gram) of tokens with its hash.
public struct Shingle: Sendable, Hashable {
    // MARK: Lifecycle

    public init(hash: UInt64, position: Int, tokens: [String]) {
        self.hash = hash
        self.position = position
        self.tokens = tokens
    }

    // MARK: Public

    /// Hash value of the shingle.
    public let hash: UInt64

    /// Starting position in the token sequence.
    public let position: Int

    /// The tokens comprising this shingle (for debugging).
    public let tokens: [String]
}

// MARK: - ShingledDocument

/// A document (code block) represented as a set of shingles.
public struct ShingledDocument: Sendable {
    // MARK: Lifecycle

    public init(
        file: String,
        startLine: Int,
        endLine: Int,
        tokenCount: Int,
        shingleHashes: Set<UInt64>,
        shingles: [Shingle],
        id: Int,
    ) {
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.tokenCount = tokenCount
        self.shingleHashes = shingleHashes
        self.shingles = shingles
        self.id = id
    }

    // MARK: Public

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
}

// MARK: - ShingleGenerator

/// Generates shingles from token sequences.
public struct ShingleGenerator: Sendable {
    // MARK: Lifecycle

    public init(shingleSize: Int = 5, normalize: Bool = true) {
        self.shingleSize = max(1, shingleSize)
        self.normalize = normalize
    }

    // MARK: Public

    /// Size of each shingle (number of tokens).
    public let shingleSize: Int

    /// Whether to normalize identifiers/literals.
    public let normalize: Bool

    /// Generate shingles from a token sequence.
    ///
    /// - Parameters:
    ///   - tokens: The token texts.
    ///   - kinds: The token kinds (for normalization).
    /// - Returns: Array of shingles.
    public func generate(tokens: [String], kinds: [TokenKind]? = nil) -> [Shingle] {
        generate(tokens: ArraySlice(tokens), kinds: kinds.map { ArraySlice($0) })
    }

    /// Generate shingles from a slice of a token sequence.
    ///
    /// Accepting `ArraySlice` lets the duplication-detector hot path
    /// (`generateBlockDocuments`) reuse a single owning `[String]` /
    /// `[TokenKind]` allocation across many block windows, instead of
    /// `Array(tokens[i..<j])`-copying per window.
    func generate(tokens: ArraySlice<String>, kinds: ArraySlice<TokenKind>?) -> [Shingle] {
        guard tokens.count >= shingleSize else { return [] }

        let normalizedTokens: ArraySlice<String> =
            if normalize, let kinds {
                ArraySlice(normalizeTokens(Array(tokens), kinds: Array(kinds)))
            } else {
                tokens
            }

        var shingles: [Shingle] = []
        shingles.reserveCapacity(normalizedTokens.count - shingleSize + 1)

        for (i, window) in normalizedTokens.windows(ofCount: shingleSize).enumerated() {
            let shingleTokens = Array(window)
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
        id: Int,
    ) -> ShingledDocument {
        let tokens = sequence.tokens.map(\.text)
        let kinds = sequence.tokens.map(\.kind)
        let shingles = generate(tokens: ArraySlice(tokens), kinds: ArraySlice(kinds))

        let startLine = sequence.tokens.first?.line ?? 1
        let endLine = sequence.tokens.last?.line ?? startLine

        return ShingledDocument(
            file: sequence.file,
            startLine: startLine,
            endLine: endLine,
            tokenCount: sequence.tokens.count,
            shingleHashes: shingleHashSet(from: shingles),
            shingles: shingles,
            id: id,
        )
    }

    /// Generate shingled documents from code blocks within a file.
    ///
    /// This breaks the file into logical blocks (functions, classes) for comparison.
    ///
    /// 0.3.0-α.3: rewritten to iterate `ArraySlice<TokenInfo>` directly.
    /// Pre-0.3 the hot path materialised `[String]` and `[TokenKind]`
    /// arrays via `sequence.tokens.map(\.text)` /
    /// `sequence.tokens.map(\.kind)` once per file — two N-element
    /// allocations on the hottest duplication code path. Now the
    /// per-window iterator operates on `sequence.tokens[i..<j]` and
    /// the shared shingle/normalize pipeline derives strings and
    /// kinds on demand from the same `TokenInfo` slice.
    ///
    /// - Parameters:
    ///   - sequence: The full file token sequence.
    ///   - blockSize: Minimum tokens per block.
    ///   - startId: Starting ID for documents.
    /// - Returns: Array of shingled documents.
    public func generateBlockDocuments(
        from sequence: TokenSequence,
        blockSize: Int,
        startId: Int,
    ) -> [ShingledDocument] {
        guard sequence.tokens.count >= blockSize else { return [] }

        let stride = max(1, blockSize / 2)  // 50% overlap

        var documents: [ShingledDocument] = []
        documents.reserveCapacity((sequence.tokens.count - blockSize) / stride + 1)
        var currentId = startId

        var i = 0
        while i + blockSize <= sequence.tokens.count {
            let blockTokens = sequence.tokens[i..<(i + blockSize)]
            let shingles = generate(tokenInfos: blockTokens)

            let startLine = sequence.tokens[i].line
            let endLine = sequence.tokens[i + blockSize - 1].line

            documents.append(
                ShingledDocument(
                    file: sequence.file,
                    startLine: startLine,
                    endLine: endLine,
                    tokenCount: blockSize,
                    shingleHashes: shingleHashSet(from: shingles),
                    shingles: shingles,
                    id: currentId,
                ))

            currentId += 1
            i += stride
        }

        return documents
    }

    /// Generate shingles directly from a `TokenInfo` slice, avoiding the
    /// two per-file `[String]` / `[TokenKind]` allocations that the
    /// `(tokens: ArraySlice<String>, kinds: ArraySlice<TokenKind>?)`
    /// overload triggers when invoked from
    /// `generateBlockDocuments`. Normalisation reads `text`/`kind`
    /// directly off each `TokenInfo`; per-window text strings are
    /// captured lazily and only the shingle hash + a single
    /// `[String]` slot in `Shingle.tokens` survive (callers can
    /// inspect the raw window if they care).
    func generate(tokenInfos: ArraySlice<TokenInfo>) -> [Shingle] {
        guard tokenInfos.count >= shingleSize else { return [] }

        // Normalised text per position. Reuses one growing dictionary
        // per call instead of the pre-0.3 path's helper-allocated
        // `[String]` return value.
        let normalised: [String]
        if normalize {
            normalised = normalizeTokenInfos(tokenInfos)
        } else {
            // No normalisation: capture the raw text strings as we go.
            normalised = tokenInfos.map(\.text)
        }

        var shingles: [Shingle] = []
        shingles.reserveCapacity(normalised.count - shingleSize + 1)

        let windowCount = normalised.count - shingleSize + 1
        for i in 0..<windowCount {
            let window = Array(normalised[i..<(i + shingleSize)])
            let hash = computeShingleHash(window)
            shingles.append(Shingle(hash: hash, position: i, tokens: window))
        }

        return shingles
    }

    /// Normalise a `TokenInfo` slice into a flat `[String]`, mirroring
    /// `normalizeTokens(_:kinds:)` but driven by the paired
    /// `(text, kind)` data sitting inside each `TokenInfo`. Avoids
    /// allocating intermediate `[String]` / `[TokenKind]` columns.
    private func normalizeTokenInfos(_ tokenInfos: ArraySlice<TokenInfo>) -> [String] {
        var result: [String] = []
        result.reserveCapacity(tokenInfos.count)
        var identifierMap: [String: String] = [:]
        var literalMap: [String: String] = [:]
        var identifierCount = 0
        var literalCount = 0

        for info in tokenInfos {
            switch info.kind {
            case .identifier:
                if let normalized = identifierMap[info.text] {
                    result.append(normalized)
                } else {
                    let normalized = "$ID\(identifierCount)"
                    identifierMap[info.text] = normalized
                    identifierCount += 1
                    result.append(normalized)
                }

            case .literal:
                if let normalized = literalMap[info.text] {
                    result.append(normalized)
                } else {
                    let normalized = "$LIT\(literalCount)"
                    literalMap[info.text] = normalized
                    literalCount += 1
                    result.append(normalized)
                }

            default:
                result.append(info.text)
            }
        }

        return result
    }

    /// Build the `Set<UInt64>` of shingle hashes without the intermediate
    /// `[UInt64]` that `Set(shingles.map(\.hash))` would allocate. Reserves
    /// up to `shingles.count` slots since hash collisions are negligible.
    private func shingleHashSet(from shingles: [Shingle]) -> Set<UInt64> {
        var hashes = Set<UInt64>()
        hashes.reserveCapacity(shingles.count)
        for shingle in shingles {
            hashes.insert(shingle.hash)
        }
        return hashes
    }

    // MARK: Private

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
    ///
    /// Uses 0xFF as the inter-token separator so that two different token
    /// splits with the same concatenated bytes still produce distinct hashes.
    private func computeShingleHash(_ tokens: [String]) -> UInt64 {
        var hash = FNV1a.offsetBasis

        for token in tokens {
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* FNV1a.prime
            }
            hash ^= 0xFF
            hash = hash &* FNV1a.prime
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

        for window in chars.windows(ofCount: k) {
            let shingle = String(window)
            hashes.insert(computeStringHash(shingle))
        }

        return hashes
    }

    /// Compute hash for a string.
    private func computeStringHash(_ string: String) -> UInt64 {
        FNV1a.hash(string)
    }
}
