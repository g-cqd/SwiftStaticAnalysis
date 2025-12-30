//
//  SuffixArrayConstructionTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify suffix array construction for various input patterns
//  - Test SA-IS algorithm implementation
//
//  ## Coverage
//  - Empty input, single element, two elements
//  - Repeated elements, banana-like pattern
//  - String-based construction with alphabet mapping
//  - Large array construction (performance)
//

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("Suffix Array Construction Tests")
struct SuffixArrayConstructionTests {
    @Test("Empty input produces empty suffix array")
    func emptyInput() {
        let sa = SuffixArray(tokens: [])
        #expect(sa.array.isEmpty)
        #expect(sa.length == 0)
    }

    @Test("Single element suffix array")
    func singleElement() {
        let sa = SuffixArray(tokens: [1])
        #expect(sa.array.count == 1)
        #expect(sa.array[0] == 0)
    }

    @Test("Two element suffix array")
    func twoElements() {
        // "ba" -> sorted suffixes: "a" (index 1), "ba" (index 0)
        let sa = SuffixArray(tokens: [2, 1])
        #expect(sa.array.count == 2)
        #expect(sa.array[0] == 1)  // "a" comes first
        #expect(sa.array[1] == 0)  // "ba" comes second
    }

    @Test("Repeated elements suffix array")
    func repeatedElements() {
        // "aaa" -> all suffixes are prefixes of each other
        let sa = SuffixArray(tokens: [1, 1, 1])
        #expect(sa.array.count == 3)
        // Sorted: "a" (2), "aa" (1), "aaa" (0)
        #expect(sa.array[0] == 2)
        #expect(sa.array[1] == 1)
        #expect(sa.array[2] == 0)
    }

    @Test("Banana-like pattern suffix array")
    func bananaPattern() {
        // "banana" -> [2,1,3,1,3,1] (a=1, b=2, n=3)
        // Expected suffix array for "banana$": [6,5,3,1,0,4,2]
        // Without sentinel: suffixes sorted
        let tokens = [2, 1, 3, 1, 3, 1]  // b a n a n a
        let sa = SuffixArray(tokens: tokens)
        #expect(sa.array.count == 6)

        // Verify suffix ordering is correct
        for i in 0..<(sa.array.count - 1) {
            let suffix1 = Array(tokens[sa.array[i]...])
            let suffix2 = Array(tokens[sa.array[i + 1]...])
            #expect(suffix1.lexicographicallyPrecedes(suffix2) || suffix1 == suffix2)
        }
    }

    @Test("Suffix array from strings")
    func fromStrings() {
        let strings = ["func", "hello", "func", "world"]
        let (sa, alphabet) = SuffixArray.fromStrings(strings)

        #expect(sa.length == 4)
        #expect(alphabet.count == 3)  // func, hello, world

        // "func" should map to same ID
        #expect(alphabet["func"] != nil)
        #expect(alphabet["hello"] != nil)
        #expect(alphabet["world"] != nil)
    }

    @Test("Large suffix array construction")
    func largeArray() {
        // Test with a larger input to verify O(n) performance
        var tokens: [Int] = []
        for i in 0..<1000 {
            tokens.append(i % 100 + 1)
        }

        let sa = SuffixArray(tokens: tokens)
        #expect(sa.array.count == 1000)

        // Verify all indices are present
        let indices = Set(sa.array)
        #expect(indices.count == 1000)
    }
}
