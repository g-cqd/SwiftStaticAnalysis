//  DeterministicEmbeddingProvider.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - DeterministicEmbeddingProvider

/// A deterministic, dependency-free embedding provider used for smoke-tests,
/// CI without model bundles, and self-contained `EmbeddingCloneDiscovery`
/// drives where a real semantic model is not yet wired in.
///
/// Produces a stable `[Float]` vector by hashing character n-grams into
/// bucketed counts. NOT semantically meaningful — code that differs only by
/// renamed identifiers will hash to distinct buckets. Use a real Core ML
/// model (`CoreMLSemanticEmbeddingProvider`) for production semantic detection.
public struct DeterministicEmbeddingProvider: SemanticEmbeddingProvider {
    public init(dimension: Int = 128, ngramSize: Int = 3) {
        precondition(dimension > 0, "dimension must be > 0")
        precondition(ngramSize > 0, "ngramSize must be > 0")
        self.embeddingDimension = dimension
        self.ngramSize = ngramSize
    }

    public let embeddingDimension: Int
    public let ngramSize: Int

    public func embed(snippet: String) async throws -> [Float] {
        var buckets = [Float](repeating: 0, count: embeddingDimension)
        let chars = Array(snippet.unicodeScalars)
        guard chars.count >= ngramSize else { return buckets }

        for i in 0...(chars.count - ngramSize) {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV-1a offset basis
            for j in 0..<ngramSize {
                hash ^= UInt64(chars[i + j].value)
                hash = hash &* 0x0000_0100_0000_01B3  // FNV-1a prime
            }
            let bucket = Int(hash % UInt64(embeddingDimension))
            buckets[bucket] += 1
        }

        return buckets
    }
}
