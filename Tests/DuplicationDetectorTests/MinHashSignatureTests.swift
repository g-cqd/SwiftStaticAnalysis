//
//  MinHashSignatureTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify MinHash signature computation
//  - Test similarity estimation accuracy
//
//  ## Coverage
//  - Identical sets produce similarity 1.0
//  - Disjoint sets produce low similarity
//  - Partial overlap similarity estimation
//  - Empty set signature behavior
//  - Deterministic signatures with same seed
//  - Different seeds produce different signatures
//

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("MinHash Signature Tests")
struct MinHashSignatureTests {
    @Test("Identical sets have similarity 1.0")
    func identicalSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 100)
        let hashes: Set<UInt64> = [1, 2, 3, 4, 5]

        let sig1 = generator.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes, documentId: 1)

        let similarity = sig1.estimateSimilarity(with: sig2)
        #expect(abs(similarity - 1.0) < 0.01)
    }

    @Test("Disjoint sets have low similarity")
    func disjointSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 100)
        let hashes1: Set<UInt64> = [1, 2, 3, 4, 5]
        let hashes2: Set<UInt64> = [100, 200, 300, 400, 500]

        let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

        let similarity = sig1.estimateSimilarity(with: sig2)
        #expect(similarity < 0.2)  // Should be very low
    }

    @Test("Partial overlap similarity estimation")
    func partialOverlapSimilarity() {
        let generator = MinHashGenerator(numHashes: 256)
        let common: Set<UInt64> = Set(1...50)
        let unique1: Set<UInt64> = Set(51...100)
        let unique2: Set<UInt64> = Set(101...150)

        let hashes1 = common.union(unique1)  // 100 elements, 50 in common
        let hashes2 = common.union(unique2)  // 100 elements, 50 in common

        // Exact Jaccard = 50 / 150 = 0.333
        let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

        let estimated = sig1.estimateSimilarity(with: sig2)
        let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

        #expect(abs(estimated - exact) < 0.1)  // Within 10%
    }

    @Test("Empty set signature")
    func emptySetSignature() {
        let generator = MinHashGenerator(numHashes: 64)
        let sig = generator.computeSignature(for: [], documentId: 0)

        #expect(sig.size == 64)
        #expect(sig.values.allSatisfy { $0 == UInt64.max })
    }

    @Test("Deterministic signatures with same seed")
    func deterministicSignatures() {
        let generator = MinHashGenerator(numHashes: 100, seed: 12345)
        let hashes: Set<UInt64> = [10, 20, 30, 40, 50]

        let sig1 = generator.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes, documentId: 1)

        // Same input should produce same signature values (different IDs)
        #expect(sig1.values == sig2.values)
    }

    @Test("Different seeds produce different signatures")
    func differentSeedsProduceDifferentSignatures() {
        let generator1 = MinHashGenerator(numHashes: 100, seed: 1)
        let generator2 = MinHashGenerator(numHashes: 100, seed: 2)
        let hashes: Set<UInt64> = [10, 20, 30, 40, 50]

        let sig1 = generator1.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator2.computeSignature(for: hashes, documentId: 0)

        #expect(sig1.values != sig2.values)
    }
}
