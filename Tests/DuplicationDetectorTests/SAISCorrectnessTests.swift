//  SAISCorrectnessTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("SA-IS Algorithm Correctness Tests")
struct SAISCorrectnessTests {
    @Test("Suffix array is a permutation")
    func suffixArrayPermutation() {
        let tokens = [3, 1, 4, 1, 5, 9, 2, 6]
        let sa = SuffixArray(tokens: tokens)

        // Check that SA is a permutation of [0, n-1]
        let sorted = sa.array.sorted()
        #expect(sorted == Array(0..<tokens.count))
    }

    @Test("Suffixes are lexicographically sorted")
    func suffixesSorted() {
        let tokens = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5]
        let sa = SuffixArray(tokens: tokens)

        // Verify each adjacent pair is in correct order
        for i in 0..<(sa.array.count - 1) {
            let suffix1 = Array(tokens[sa.array[i]...])
            let suffix2 = Array(tokens[sa.array[i + 1]...])

            let isOrdered =
                suffix1.lexicographicallyPrecedes(suffix2) || suffix1.starts(with: suffix2)
                || suffix2.starts(with: suffix1)
            #expect(isOrdered, "Suffixes at SA[\(i)] and SA[\(i + 1)] are not properly ordered")
        }
    }

    @Test("All ones input")
    func allOnesInput() {
        let tokens = [Int](repeating: 1, count: 10)
        let sa = SuffixArray(tokens: tokens)

        // For all-same elements, SA should be [9,8,7,6,5,4,3,2,1,0]
        // (shortest suffix first)
        #expect(sa.array.count == 10)
        for i in 0..<10 {
            #expect(sa.array[i] == 9 - i)
        }
    }

    @Test("Descending input")
    func descendingInput() {
        let tokens = [5, 4, 3, 2, 1]
        let sa = SuffixArray(tokens: tokens)

        // For strictly descending, SA should be [4,3,2,1,0]
        #expect(sa.array == [4, 3, 2, 1, 0])
    }

    @Test("Ascending input")
    func ascendingInput() {
        let tokens = [1, 2, 3, 4, 5]
        let sa = SuffixArray(tokens: tokens)

        // For strictly ascending, SA should be [0,1,2,3,4]
        #expect(sa.array == [0, 1, 2, 3, 4])
    }
}
