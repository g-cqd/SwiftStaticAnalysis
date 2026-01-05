//  BatchProcessingTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("Batch Processing Tests")
struct BatchProcessingTests {
    @Test("Batch compute signatures")
    func batchComputeSignatures() {
        let generator = MinHashGenerator(numHashes: 64)
        let shingleGen = ShingleGenerator(shingleSize: 2, normalize: false)

        var documents: [ShingledDocument] = []
        for i in 0..<5 {
            let tokens = ["token\(i)", "token\(i + 1)", "token\(i + 2)"]
            let shingles = shingleGen.generate(tokens: tokens, kinds: nil)
            documents.append(
                ShingledDocument(
                    file: "file\(i).swift",
                    startLine: 1, endLine: 1,
                    tokenCount: tokens.count,
                    shingleHashes: Set(shingles.map(\.hash)),
                    shingles: shingles,
                    id: i,
                ))
        }

        let signatures = generator.computeSignatures(for: documents)
        #expect(signatures.count == 5)
        for (i, sig) in signatures.enumerated() {
            #expect(sig.documentId == i)
            #expect(sig.size == 64)
        }
    }

    @Test("Pairwise similarities computation")
    func pairwiseSimilarities() {
        let generator = MinHashGenerator(numHashes: 64)

        // Create 3 similar signatures
        let common: Set<UInt64> = Set((0..<50).map { UInt64($0) })
        let sig1 = generator.computeSignature(for: common.union([100]), documentId: 1)
        let sig2 = generator.computeSignature(for: common.union([200]), documentId: 2)
        let sig3 = generator.computeSignature(for: common.union([300]), documentId: 3)

        let pairs = generator.computePairwiseSimilarities([sig1, sig2, sig3], threshold: 0.5)

        // Should find pairs with high similarity
        #expect(!pairs.isEmpty)  // May vary based on hash function
        for pair in pairs {
            #expect(pair.similarity >= 0.5)
        }
    }
}
