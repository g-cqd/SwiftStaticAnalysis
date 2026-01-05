//  LCPCorrectnessTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("LCP Correctness Tests")
struct LCPCorrectnessTests {
    @Test("LCP values are correct")
    func lcpValuesCorrect() {
        let tokens = [1, 2, 1, 2, 1]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        // Verify LCP values by computing them directly
        for i in 1..<lcp.array.count {
            let pos1 = sa.array[i - 1]
            let pos2 = sa.array[i]

            // Compute expected LCP
            var expectedLCP = 0
            while pos1 + expectedLCP < tokens.count,
                pos2 + expectedLCP < tokens.count,
                tokens[pos1 + expectedLCP] == tokens[pos2 + expectedLCP]
            {
                expectedLCP += 1
            }

            #expect(
                lcp.array[i] == expectedLCP,
                "LCP[\(i)] should be \(expectedLCP) but got \(lcp.array[i])")
        }
    }

    @Test("LCP with no common prefixes")
    func lcpNoCommonPrefixes() {
        let tokens = [5, 4, 3, 2, 1]  // Strictly descending
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        // Adjacent suffixes have no common prefix
        for i in 1..<lcp.array.count {
            #expect(lcp.array[i] == 0)
        }
    }

    @Test("LCP with long common prefix")
    func lcpLongCommonPrefix() {
        // "abcabcabc" has long common prefixes
        let tokens = [1, 2, 3, 1, 2, 3, 1, 2, 3]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        let maxLCP = lcp.array.max() ?? 0
        #expect(maxLCP >= 6)  // "abcabc" appears twice
    }
}
