//
//  MinHashAccuracyTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify MinHash similarity estimation accuracy
//  - Test accuracy at various thresholds and set sizes
//
//  ## Coverage
//  - Accuracy at 0.2, 0.5, 0.8 similarity thresholds
//  - Large set similarity estimation
//

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("MinHash Accuracy Tests")
struct MinHashAccuracyTests {
    @Test("Similarity estimation accuracy at various thresholds")
    func similarityEstimationAccuracy() {
        let generator = MinHashGenerator(numHashes: 256)

        // Test at various Jaccard similarities
        for targetSim in stride(from: 0.2, through: 0.8, by: 0.3) {
            let overlapSize = 100
            let totalSize = Int(Double(overlapSize) / targetSim)
            let uniquePerSet = (totalSize - overlapSize) / 2

            let common: Set<UInt64> = Set((0..<overlapSize).map { UInt64($0) })
            let unique1: Set<UInt64> = Set((1000..<(1000 + uniquePerSet)).map { UInt64($0) })
            let unique2: Set<UInt64> = Set((2000..<(2000 + uniquePerSet)).map { UInt64($0) })

            let hashes1 = common.union(unique1)
            let hashes2 = common.union(unique2)

            let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
            let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

            let estimated = sig1.estimateSimilarity(with: sig2)
            let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

            #expect(abs(estimated - exact) < 0.15)
        }
    }

    @Test("Large sets similarity")
    func largeSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 128)
        let size = 10000
        let overlapRatio = 0.6

        let overlapSize = Int(Double(size) * overlapRatio)
        let common: Set<UInt64> = Set((0..<overlapSize).map { UInt64($0) })
        let unique1: Set<UInt64> = Set((size..<(2 * size - overlapSize)).map { UInt64($0) })
        let unique2: Set<UInt64> = Set(((2 * size)..<(3 * size - overlapSize)).map { UInt64($0) })

        let hashes1 = common.union(unique1)
        let hashes2 = common.union(unique2)

        let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

        let estimated = sig1.estimateSimilarity(with: sig2)
        let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

        #expect(abs(estimated - exact) < 0.1)
    }
}
