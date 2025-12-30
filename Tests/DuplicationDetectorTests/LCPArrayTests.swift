//
//  LCPArrayTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify LCP (Longest Common Prefix) array construction
//  - Test repeat detection using LCP values
//
//  ## Coverage
//  - LCPArray: empty, single element, repeated sequence
//  - findRepeatsAboveThreshold, findMaximalRepeats, findRepeatGroups
//

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("LCP Array Tests")
struct LCPArrayTests {
    @Test("Empty LCP array")
    func emptyLCP() {
        let sa = SuffixArray(tokens: [])
        let lcp = LCPArray(suffixArray: sa, tokens: [])
        #expect(lcp.array.isEmpty)
    }

    @Test("Single element LCP array")
    func singleElementLCP() {
        let tokens = [1]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)
        #expect(lcp.array.count == 1)
        #expect(lcp.array[0] == 0)
    }

    @Test("LCP array with repeated sequence")
    func lcpRepeatedSequence() {
        // "abcabc" - has repeat of length 3
        let tokens = [1, 2, 3, 1, 2, 3]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        // There should be LCP values of 3 or more
        let maxLCP = lcp.array.max() ?? 0
        #expect(maxLCP >= 3)
    }

    @Test("Find repeats above threshold")
    func findRepeatsAboveThreshold() {
        let tokens = [1, 2, 3, 1, 2, 3, 4, 1, 2, 3]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        let positions = lcp.findRepeatsAboveThreshold(3)
        #expect(!positions.isEmpty)
    }

    @Test("Find maximal repeats")
    func findMaximalRepeats() {
        // Input with clear repeated pattern
        let tokens = [1, 2, 3, 4, 5, 1, 2, 3, 4, 5]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        let repeats = lcp.findMaximalRepeats(minLength: 3)

        // Should find the repeated [1,2,3,4,5] pattern
        #expect(!repeats.isEmpty)
        let maxRepeat = repeats.max { $0.length < $1.length }
        #expect(maxRepeat?.length == 5)
        #expect(maxRepeat?.occurrences == 2)
    }

    @Test("Find repeat groups")
    func findRepeatGroups() {
        let tokens = [1, 2, 3, 1, 2, 3]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        let groups = lcp.findRepeatGroups(minLength: 3)

        #expect(!groups.isEmpty)
        if let group = groups.first {
            #expect(group.length >= 3)
            #expect(group.occurrences >= 2)
        }
    }
}
