//  MinHash.swift
//  SwiftStaticAnalysis
//  MIT License

import Algorithms
import Foundation

#if canImport(simd)
    import simd
#endif

// MARK: - Mersenne-prime arithmetic

/// 2^61 − 1: the largest Mersenne prime that fits inside `UInt64`. Used as
/// the MinHash modulus because reduction modulo it collapses to a couple
/// of shifts and masks, with no 64-bit hardware divide.
@inlinable
func mersenne61Reduce(_ value: UInt64) -> UInt64 {
    // `(r & M) + (r >> 61)` reduces values < 2^122 to < 2 * M; one more
    // fold caps the result at < M. Coefficients are kept < 2^61, so the
    // (a * x + b) product fits in 2 * 2^61 before this reduction.
    let mask: UInt64 = (1 &<< 61) &- 1
    let result = (value & mask) &+ (value &>> 61)
    return result >= mask ? result &- mask : result
}

/// SplitMix64 — the standard high-quality 64-bit PRNG for seeding other
/// algorithms. Replaces the LCG-derived `(rng >> 33) | 1` mixer used in
/// the original MinHash coefficient generator.
@inlinable
func splitMix64(_ state: inout UInt64) -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value &>> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value &>> 27)) &* 0x94D0_49BB_1331_11EB
    value = value ^ (value &>> 31)
    return value
}

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

    public init(numHashes: Int = 256, seed: UInt64 = 42) {
        self.numHashes = numHashes

        // Generate independent coefficients via SplitMix64. The Mersenne-prime
        // reduction requires `a` and `b` < M_61, so each draw is masked to
        // 61 bits; `a` is forced non-zero so the universal-hash family is
        // injective.
        let mask: UInt64 = (1 &<< 61) &- 1
        var rng = seed
        var a: [UInt64] = []
        var b: [UInt64] = []
        a.reserveCapacity(numHashes)
        b.reserveCapacity(numHashes)

        for _ in 0..<numHashes {
            var coefficientA = splitMix64(&rng) & mask
            if coefficientA == 0 { coefficientA = 1 }
            a.append(coefficientA)
            b.append(splitMix64(&rng) & mask)
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

    /// Mersenne prime M_61 = 2^61 − 1. Used as the universal-hashing
    /// modulus because reduction is branch-free shifts and masks, suitable
    /// for SIMD lanes.
    @usableFromInline static let mersenne61: UInt64 = (1 &<< 61) &- 1

    /// Pre-computed hash function coefficients (each < 2^61 so that the
    /// product `a * shingle` stays within the Mersenne-reduction window).
    private let coefficientsA: [UInt64]
    private let coefficientsB: [UInt64]

    // MARK: - Private Implementation

    /// Scalar implementation of MinHash computation. Identical bit-for-bit
    /// to the SIMD path; kept for `numHashes < 4` and as a reference for
    /// the equivalence test.
    private func computeSignatureScalar(for hashes: [UInt64]) -> [UInt64] {
        var signature = [UInt64](repeating: UInt64.max, count: numHashes)

        for shingleHash in hashes {
            let x = shingleHash & Self.mersenne61
            for i in 0..<numHashes {
                let h = mersenne61Reduce(coefficientsA[i] &* x &+ coefficientsB[i])
                signature[i] = min(signature[i], h)
            }
        }

        return signature
    }

    /// Vectorised implementation of MinHash computation.
    ///
    /// Processes 4 hash functions at a time using `SIMD4<UInt64>`. The
    /// modulus is the Mersenne prime `M_61 = 2^61 − 1`, so reduction is
    /// `(r & M_61) + (r >> 61)` with one fold for carry — no hardware
    /// divide, fully SIMD-vectorisable across the lane.
    private func computeSignatureSIMD(for hashes: [UInt64]) -> [UInt64] {
        var signature = [UInt64](repeating: UInt64.max, count: numHashes)

        let chunks = numHashes / 4
        let mask = SIMD4<UInt64>(repeating: Self.mersenne61)

        coefficientsA.withUnsafeBufferPointer { aPtr in
            coefficientsB.withUnsafeBufferPointer { bPtr in
                signature.withUnsafeMutableBufferPointer { sigPtr in
                    for shingleHash in hashes {
                        let x = SIMD4<UInt64>(repeating: shingleHash & Self.mersenne61)

                        for chunk in 0..<chunks {
                            let baseIdx = chunk * 4
                            let a = SIMD4<UInt64>(
                                aPtr[baseIdx],
                                aPtr[baseIdx + 1],
                                aPtr[baseIdx + 2],
                                aPtr[baseIdx + 3]
                            )
                            let b = SIMD4<UInt64>(
                                bPtr[baseIdx],
                                bPtr[baseIdx + 1],
                                bPtr[baseIdx + 2],
                                bPtr[baseIdx + 3]
                            )

                            // (a * x + b) using wrapping arithmetic, then
                            // Mersenne-61 reduction folded once.
                            var product = a &* x &+ b
                            product = (product & mask) &+ (product &>> 61)
                            // One more conditional fold for the carry.
                            let overflow: SIMD4<UInt64> = SIMD4<UInt64>(
                                product[0] >= Self.mersenne61 ? Self.mersenne61 : 0,
                                product[1] >= Self.mersenne61 ? Self.mersenne61 : 0,
                                product[2] >= Self.mersenne61 ? Self.mersenne61 : 0,
                                product[3] >= Self.mersenne61 ? Self.mersenne61 : 0
                            )
                            product = product &- overflow

                            // SIMD min into the running signature.
                            let current = SIMD4<UInt64>(
                                sigPtr[baseIdx],
                                sigPtr[baseIdx + 1],
                                sigPtr[baseIdx + 2],
                                sigPtr[baseIdx + 3]
                            )
                            let reduced = pointwiseMin(current, product)
                            sigPtr[baseIdx] = reduced[0]
                            sigPtr[baseIdx + 1] = reduced[1]
                            sigPtr[baseIdx + 2] = reduced[2]
                            sigPtr[baseIdx + 3] = reduced[3]
                        }

                        // Scalar tail for the remainder.
                        for i in (chunks * 4)..<numHashes {
                            let h = mersenne61Reduce(aPtr[i] &* x[0] &+ bPtr[i])
                            sigPtr[i] = min(sigPtr[i], h)
                        }
                    }
                }
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

    public init(numHashes: Int = 256, seed: UInt64 = 42) {
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
