//
//  ExactJaccardTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify exact Jaccard similarity computation
//  - Test edge cases
//
//  ## Coverage
//  - Empty sets, one empty set
//  - Identical sets, disjoint sets
//  - Partial overlap calculation
//

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("Exact Jaccard Similarity Tests")
struct ExactJaccardTests {
    @Test("Empty sets have zero similarity")
    func emptySets() {
        let empty: Set<UInt64> = []
        let sim = MinHashGenerator.exactJaccardSimilarity(empty, empty)
        #expect(sim == 0.0)
    }

    @Test("One empty set has zero similarity")
    func oneEmptySet() {
        let empty: Set<UInt64> = []
        let nonEmpty: Set<UInt64> = [1, 2, 3]
        let sim = MinHashGenerator.exactJaccardSimilarity(empty, nonEmpty)
        #expect(sim == 0.0)
    }

    @Test("Identical sets have similarity 1.0")
    func identicalSets() {
        let set1: Set<UInt64> = [1, 2, 3, 4, 5]
        let sim = MinHashGenerator.exactJaccardSimilarity(set1, set1)
        #expect(sim == 1.0)
    }

    @Test("Disjoint sets have similarity 0.0")
    func disjointSets() {
        let set1: Set<UInt64> = [1, 2, 3]
        let set2: Set<UInt64> = [4, 5, 6]
        let sim = MinHashGenerator.exactJaccardSimilarity(set1, set2)
        #expect(sim == 0.0)
    }

    @Test("Partial overlap has correct similarity")
    func partialOverlap() {
        // Set1: {1, 2, 3}, Set2: {2, 3, 4}
        // Intersection: {2, 3} = 2
        // Union: {1, 2, 3, 4} = 4
        // Jaccard = 2/4 = 0.5
        let set1: Set<UInt64> = [1, 2, 3]
        let set2: Set<UInt64> = [2, 3, 4]
        let sim = MinHashGenerator.exactJaccardSimilarity(set1, set2)
        #expect(sim == 0.5)
    }
}
