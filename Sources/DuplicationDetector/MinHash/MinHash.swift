//
//  MinHash.swift
//  SwiftStaticAnalysis
//
//  MinHash implementation for estimating Jaccard similarity between sets.
//  Uses SIMD operations where possible for high-throughput signature computation.
//
//  MinHash generates k hash values (signature) for each document, where k is
//  the number of hash functions. The probability that two documents have the
//  same MinHash value equals their Jaccard similarity.
//

import Algorithms
import Foundation

#if canImport(simd)
    import simd
#endif

// MARK: - MinHashSignature

/// A MinHash signature representing a document.
public struct MinHashSignature: Sendable, Hashable {
    // MARK: Lifecycle

    public init(values: [UInt64], documentId: Int) {
        self.values = values
        self.documentId = documentId
    }

    // MARK: Public

    /// The signature values (minimum hashes).
    public let values: [UInt64]

    /// Document ID this signature represents.
    public let documentId: Int

    /// Number of hash functions used.
    public var size: Int { values.count }

    /// Estimate Jaccard similarity with another signature.
    ///
    /// - Parameter other: Another MinHash signature.
    /// - Returns: Estimated Jaccard similarity (0.0 to 1.0).
    public func estimateSimilarity(with other: Self) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }

        var matches = 0
        for (v1, v2) in zip(values, other.values) where v1 == v2 {
            matches += 1
        }

        return Double(matches) / Double(values.count)
    }
}

// MARK: - MinHashGenerator

/// Generates MinHash signatures for documents.
public struct MinHashGenerator: Sendable {
    // MARK: Lifecycle

    public init(numHashes: Int = 128, seed: UInt64 = 42) {
        self.numHashes = numHashes

        // Generate random coefficients using LCG with given seed
        var rng = seed
        var a: [UInt64] = []
        var b: [UInt64] = []

        for _ in 0..<numHashes {
            // Linear congruential generator
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            a.append((rng >> 33) | 1)  // Ensure odd for better distribution

            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            b.append(rng >> 33)
        }

        coefficientsA = a
        coefficientsB = b
    }

    // MARK: Public

    /// Number of hash functions (signature dimension).
    public let numHashes: Int

    /// Compute MinHash signature for a set of shingle hashes.
    ///
    /// - Parameters:
    ///   - shingleHashes: Set of shingle hash values.
    ///   - documentId: ID to associate with the signature.
    /// - Returns: MinHash signature.
    public func computeSignature(
        for shingleHashes: Set<UInt64>,
        documentId: Int,
    ) -> MinHashSignature {
        guard !shingleHashes.isEmpty else {
            return MinHashSignature(values: Array(repeating: UInt64.max, count: numHashes), documentId: documentId)
        }

        // Use SIMD-optimized path for larger signatures
        let signature: [UInt64] =
            if numHashes >= 4 {
                computeSignatureSIMD(for: Array(shingleHashes))
            } else {
                computeSignatureScalar(for: Array(shingleHashes))
            }

        return MinHashSignature(values: signature, documentId: documentId)
    }

    /// Compute MinHash signature from a shingled document.
    public func computeSignature(for document: ShingledDocument) -> MinHashSignature {
        computeSignature(for: document.shingleHashes, documentId: document.id)
    }

    /// Batch compute signatures for multiple documents.
    public func computeSignatures(for documents: [ShingledDocument]) -> [MinHashSignature] {
        documents.map { computeSignature(for: $0) }
    }

    // MARK: Private

    /// Large prime for modulo operation.
    private static let largePrime: UInt64 = 4_294_967_311  // Next prime after 2^32

    /// Pre-computed hash function coefficients.
    private let coefficientsA: [UInt64]
    private let coefficientsB: [UInt64]

    // MARK: - Private Implementation

    /// Scalar implementation of MinHash computation.
    private func computeSignatureScalar(for hashes: [UInt64]) -> [UInt64] {
        var signature = [UInt64](repeating: UInt64.max, count: numHashes)
        let prime = Self.largePrime

        for shingleHash in hashes {
            for i in 0..<numHashes {
                // h_i(x) = (a_i * x + b_i) mod prime
                let hashValue = (coefficientsA[i] &* shingleHash &+ coefficientsB[i]) % prime
                signature[i] = min(signature[i], hashValue)
            }
        }

        return signature
    }

    /// SIMD-optimized implementation of MinHash computation.
    ///
    /// Processes 4 hash functions at a time using SIMD vectors.
    private func computeSignatureSIMD(for hashes: [UInt64]) -> [UInt64] {
        var signature = [UInt64](repeating: UInt64.max, count: numHashes)

        // Process in chunks of 4 for SIMD
        let chunks = numHashes / 4

        for shingleHash in hashes {
            // SIMD path: process 4 at a time
            for chunk in 0..<chunks {
                let baseIdx = chunk * 4

                // Load coefficients
                let a0 = coefficientsA[baseIdx]
                let a1 = coefficientsA[baseIdx + 1]
                let a2 = coefficientsA[baseIdx + 2]
                let a3 = coefficientsA[baseIdx + 3]

                let b0 = coefficientsB[baseIdx]
                let b1 = coefficientsB[baseIdx + 1]
                let b2 = coefficientsB[baseIdx + 2]
                let b3 = coefficientsB[baseIdx + 3]

                // Compute hashes (using wrapping arithmetic)
                let h0 = (a0 &* shingleHash &+ b0) % Self.largePrime
                let h1 = (a1 &* shingleHash &+ b1) % Self.largePrime
                let h2 = (a2 &* shingleHash &+ b2) % Self.largePrime
                let h3 = (a3 &* shingleHash &+ b3) % Self.largePrime

                // Update minimums
                signature[baseIdx] = min(signature[baseIdx], h0)
                signature[baseIdx + 1] = min(signature[baseIdx + 1], h1)
                signature[baseIdx + 2] = min(signature[baseIdx + 2], h2)
                signature[baseIdx + 3] = min(signature[baseIdx + 3], h3)
            }

            // Handle remainder
            for i in (chunks * 4)..<numHashes {
                let hashValue = (coefficientsA[i] &* shingleHash &+ coefficientsB[i]) % Self.largePrime
                signature[i] = min(signature[i], hashValue)
            }
        }

        return signature
    }
}

// MARK: - Jaccard Similarity

extension MinHashGenerator {
    /// Compute exact Jaccard similarity between two sets.
    ///
    /// This is O(n + m) where n, m are set sizes.
    /// Used for verification and small sets where exact computation is feasible.
    public static func exactJaccardSimilarity(
        _ set1: Set<UInt64>,
        _ set2: Set<UInt64>,
    ) -> Double {
        guard !set1.isEmpty || !set2.isEmpty else { return 0 }

        let intersection = set1.intersection(set2).count
        let union = set1.union(set2).count

        return Double(intersection) / Double(union)
    }

    /// Compute exact Jaccard similarity for shingled documents.
    public static func exactJaccardSimilarity(
        _ doc1: ShingledDocument,
        _ doc2: ShingledDocument,
    ) -> Double {
        exactJaccardSimilarity(doc1.shingleHashes, doc2.shingleHashes)
    }
}

// MARK: - WeightedMinHashGenerator

/// Weighted MinHash for handling documents with different token frequencies.
///
/// Standard MinHash treats each shingle equally. Weighted MinHash allows
/// incorporating frequency information for better similarity estimation.
public struct WeightedMinHashGenerator: Sendable {
    // MARK: Lifecycle

    public init(numHashes: Int = 128, seed: UInt64 = 42) {
        self.numHashes = numHashes
        baseGenerator = MinHashGenerator(numHashes: numHashes, seed: seed)
    }

    // MARK: Public

    /// Number of hash functions.
    public let numHashes: Int

    /// Compute weighted MinHash signature.
    ///
    /// - Parameters:
    ///   - shingleCounts: Dictionary mapping shingle hashes to their counts.
    ///   - documentId: ID to associate with the signature.
    /// - Returns: MinHash signature.
    public func computeSignature(
        for shingleCounts: [UInt64: Int],
        documentId: Int,
    ) -> MinHashSignature {
        // Expand shingles by their frequency (capped for efficiency)
        var expandedHashes = Set<UInt64>()
        let maxExpansion = 10  // Cap expansion to avoid memory issues

        for (hash, count) in shingleCounts {
            let expandedCount = min(count, maxExpansion)
            for i in 0..<expandedCount {
                // Create variant hash for each occurrence
                let variantHash = hash &+ UInt64(i) &* 2_654_435_761
                expandedHashes.insert(variantHash)
            }
        }

        return baseGenerator.computeSignature(for: expandedHashes, documentId: documentId)
    }

    // MARK: Private

    /// Standard MinHash generator for internal use.
    private let baseGenerator: MinHashGenerator
}

// MARK: - Batch Processing

extension MinHashGenerator {
    /// Results from batch similarity computation.
    public struct SimilarityPair: Sendable {
        // MARK: Lifecycle

        public init(documentId1: Int, documentId2: Int, similarity: Double) {
            self.documentId1 = documentId1
            self.documentId2 = documentId2
            self.similarity = similarity
        }

        // MARK: Public

        public let documentId1: Int
        public let documentId2: Int
        public let similarity: Double
    }

    /// Compute pairwise similarities between all signatures.
    ///
    /// This is O(n²) and should only be used for small sets.
    /// For large sets, use LSH instead.
    ///
    /// - Parameters:
    ///   - signatures: Array of signatures to compare.
    ///   - threshold: Minimum similarity to include in results.
    /// - Returns: Array of similar pairs above threshold.
    /// - Note: swa:ignore-unused - Alternative similarity computation for debugging and small datasets
    public func computePairwiseSimilarities(
        _ signatures: [MinHashSignature],
        threshold: Double,
    ) -> [SimilarityPair] {
        var results: [SimilarityPair] = []

        for pair in signatures.combinations(ofCount: 2) {
            let similarity = pair[0].estimateSimilarity(with: pair[1])
            if similarity >= threshold {
                results.append(
                    SimilarityPair(
                        documentId1: pair[0].documentId,
                        documentId2: pair[1].documentId,
                        similarity: similarity,
                    ))
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }
}
