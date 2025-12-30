//
//  LSHIndexTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify LSH index operations
//  - Test optimal bands/rows calculation
//
//  ## Coverage
//  - optimalBandsAndRows for various thresholds
//  - insert and query operations
//  - findCandidatePairs for similar documents
//  - queryWithSimilarity with threshold filtering
//

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("LSH Index Tests")
struct LSHIndexTests {
    @Test("Optimal bands and rows calculation")
    func optimalBandsAndRows() {
        // Test that optimal parameters produce reasonable thresholds
        let (b1, r1) = LSHIndex.optimalBandsAndRows(signatureSize: 128, threshold: 0.5)
        #expect(b1 * r1 <= 128)  // May not use all hashes
        #expect(b1 > 0)
        #expect(r1 > 0)

        let (b2, _) = LSHIndex.optimalBandsAndRows(signatureSize: 128, threshold: 0.8)
        // Higher threshold should have fewer bands (more rows)
        #expect(b2 <= b1)
    }

    @Test("Insert and query")
    func insertAndQuery() {
        let generator = MinHashGenerator(numHashes: 64)
        let hashes: Set<UInt64> = Set((0..<100).map { UInt64($0) })
        let sig1 = generator.computeSignature(for: hashes, documentId: 1)
        let sig2 = generator.computeSignature(for: hashes, documentId: 2)

        var index = LSHIndex(signatureSize: 64, threshold: 0.5)
        index.insert(sig1)
        index.insert(sig2)

        // sig1 should find sig2 as candidate
        let candidates = index.query(sig1)
        #expect(candidates.contains(2))
    }

    @Test("Find candidate pairs")
    func findCandidatePairs() {
        let generator = MinHashGenerator(numHashes: 64)

        // Create 3 similar documents
        let common: Set<UInt64> = Set((0..<50).map { UInt64($0) })
        let sig1 = generator.computeSignature(for: common.union([100, 101]), documentId: 1)
        let sig2 = generator.computeSignature(for: common.union([200, 201]), documentId: 2)
        let sig3 = generator.computeSignature(for: common.union([300, 301]), documentId: 3)

        // Create 1 dissimilar document
        let dissimilar: Set<UInt64> = Set((1000..<1100).map { UInt64($0) })
        let sig4 = generator.computeSignature(for: dissimilar, documentId: 4)

        var index = LSHIndex(signatureSize: 64, threshold: 0.5)
        index.insert([sig1, sig2, sig3, sig4])

        let pairs = index.findCandidatePairs()

        // Similar documents should be candidates
        let hasPair12 = pairs.contains(DocumentPair(id1: 1, id2: 2))
        let hasPair13 = pairs.contains(DocumentPair(id1: 1, id2: 3))
        let hasPair23 = pairs.contains(DocumentPair(id1: 2, id2: 3))

        // At least some similar pairs should be found
        #expect(hasPair12 || hasPair13 || hasPair23)
    }

    @Test("Query with similarity threshold")
    func queryWithSimilarity() {
        let generator = MinHashGenerator(numHashes: 128)

        let base: Set<UInt64> = Set((0..<100).map { UInt64($0) })
        let similar: Set<UInt64> = base.union(Set((100..<120).map { UInt64($0) }))
        let dissimilar: Set<UInt64> = Set((1000..<1100).map { UInt64($0) })

        let sigBase = generator.computeSignature(for: base, documentId: 0)
        let sigSimilar = generator.computeSignature(for: similar, documentId: 1)
        let sigDissimilar = generator.computeSignature(for: dissimilar, documentId: 2)

        var index = LSHIndex(signatureSize: 128, threshold: 0.5)
        index.insert([sigBase, sigSimilar, sigDissimilar])

        let results = index.queryWithSimilarity(sigBase, threshold: 0.5)

        // sigSimilar should be in results
        let similarResult = results.first { $0.documentId == 1 }
        #expect(similarResult != nil)
        if let result = similarResult {
            #expect(result.similarity > 0.5)
        }
    }
}
