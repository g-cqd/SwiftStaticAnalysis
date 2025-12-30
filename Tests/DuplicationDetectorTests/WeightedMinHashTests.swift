//
//  WeightedMinHashTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify weighted MinHash signature computation
//  - Test that weights affect similarity
//
//  ## Coverage
//  - Identical counts produce similarity 1.0
//  - Different weights affect similarity
//

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("Weighted MinHash Tests")
struct WeightedMinHashTests {
    @Test("Weighted signature for identical counts")
    func weightedSignature() {
        let generator = WeightedMinHashGenerator(numHashes: 64)

        let counts1: [UInt64: Int] = [1: 5, 2: 3, 3: 1]
        let counts2: [UInt64: Int] = [1: 5, 2: 3, 3: 1]

        let sig1 = generator.computeSignature(for: counts1, documentId: 0)
        let sig2 = generator.computeSignature(for: counts2, documentId: 1)

        let similarity = sig1.estimateSimilarity(with: sig2)
        #expect(abs(similarity - 1.0) < 0.01)
    }

    @Test("Different weights affect similarity")
    func differentWeights() {
        let generator = WeightedMinHashGenerator(numHashes: 128)

        // Same elements but different weights
        let counts1: [UInt64: Int] = [1: 10, 2: 1]
        let counts2: [UInt64: Int] = [1: 1, 2: 10]

        let sig1 = generator.computeSignature(for: counts1, documentId: 0)
        let sig2 = generator.computeSignature(for: counts2, documentId: 1)

        let similarity = sig1.estimateSimilarity(with: sig2)
        // Should be less than 1.0 due to different weights
        #expect(similarity < 1.0)
    }
}
