//
//  SuffixArraySearchTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify suffix array pattern search functionality
//  - Test various occurrence scenarios
//
//  ## Coverage
//  - findOccurrences: exact pattern, non-existent, single, overlapping
//

import Foundation
import Testing
@testable import DuplicationDetector

@Suite("Suffix Array Search Tests")
struct SuffixArraySearchTests {
    @Test("Search finds exact pattern")
    func searchExactPattern() {
        let tokens = [1, 2, 3, 1, 2, 3, 4]
        let sa = SuffixArray(tokens: tokens)

        let occurrences = sa.findOccurrences(of: [1, 2, 3], in: tokens)
        #expect(occurrences.count == 2)
        #expect(occurrences.contains(0))
        #expect(occurrences.contains(3))
    }

    @Test("Search returns empty for non-existent pattern")
    func searchNonExistent() {
        let tokens = [1, 2, 3, 4, 5]
        let sa = SuffixArray(tokens: tokens)

        let occurrences = sa.findOccurrences(of: [6, 7], in: tokens)
        #expect(occurrences.isEmpty)
    }

    @Test("Search finds single occurrence")
    func searchSingleOccurrence() {
        let tokens = [1, 2, 3, 4, 5]
        let sa = SuffixArray(tokens: tokens)

        let occurrences = sa.findOccurrences(of: [3, 4], in: tokens)
        #expect(occurrences.count == 1)
        #expect(occurrences[0] == 2)
    }

    @Test("Search with overlapping occurrences")
    func searchOverlapping() {
        // "aaaa" has overlapping "aa" at positions 0, 1, 2
        let tokens = [1, 1, 1, 1]
        let sa = SuffixArray(tokens: tokens)

        let occurrences = sa.findOccurrences(of: [1, 1], in: tokens)
        #expect(occurrences.count == 3)
    }
}
