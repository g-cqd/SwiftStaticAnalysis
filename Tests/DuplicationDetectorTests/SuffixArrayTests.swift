//
//  SuffixArrayTests.swift
//  SwiftStaticAnalysis
//
//  Tests for suffix array implementation and clone detection.
//

import Testing
import Foundation
@testable import DuplicationDetector

// MARK: - Suffix Array Construction Tests

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
        #expect(sa.array[0] == 1) // "a" comes first
        #expect(sa.array[1] == 0) // "ba" comes second
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
        let tokens = [2, 1, 3, 1, 3, 1] // b a n a n a
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
        #expect(alphabet.count == 3) // func, hello, world

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

// MARK: - Suffix Array Search Tests

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

// MARK: - LCP Array Tests

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
        let maxRepeat = repeats.max(by: { $0.length < $1.length })
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

// MARK: - Suffix Array Clone Detector Tests

@Suite("Suffix Array Clone Detector Tests")
struct SuffixArrayCloneDetectorTests {

    @Test("Detector initialization")
    func detectorInit() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 30)
        #expect(detector.minimumTokens == 30)
        #expect(detector.normalizeForType2 == false)
    }

    @Test("Detection with empty input")
    func detectEmptyInput() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 10)
        let result = detector.detect(in: [])
        #expect(result.isEmpty)
    }

    @Test("Detection with single sequence below threshold")
    func detectBelowThreshold() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 100)

        let tokens = (0..<50).map { TokenInfo(kind: .identifier, text: "t\($0)", line: $0, column: 0) }
        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])

        let result = detector.detect(in: [sequence])
        #expect(result.isEmpty)
    }
}

// MARK: - Duplication Detector Algorithm Tests

@Suite("Duplication Detector Algorithm Tests")
struct DuplicationDetectorAlgorithmTests {

    @Test("Default configuration uses rolling hash")
    func defaultAlgorithm() {
        let config = DuplicationConfiguration()
        #expect(config.algorithm == .rollingHash)
    }

    @Test("High performance configuration uses suffix array")
    func highPerformanceAlgorithm() {
        let config = DuplicationConfiguration.highPerformance
        #expect(config.algorithm == .suffixArray)
        #expect(config.cloneTypes.contains(.exact))
        #expect(config.cloneTypes.contains(.near))
    }

    @Test("Custom algorithm configuration")
    func customAlgorithm() {
        let config = DuplicationConfiguration(
            minimumTokens: 25,
            cloneTypes: [.exact],
            algorithm: .suffixArray
        )
        #expect(config.algorithm == .suffixArray)
        #expect(config.minimumTokens == 25)
    }
}

// MARK: - SA-IS Algorithm Correctness Tests

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

            let isOrdered = suffix1.lexicographicallyPrecedes(suffix2) ||
                           suffix1.starts(with: suffix2) ||
                           suffix2.starts(with: suffix1)
            #expect(isOrdered, "Suffixes at SA[\(i)] and SA[\(i+1)] are not properly ordered")
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

// MARK: - LCP Correctness Tests

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
            while pos1 + expectedLCP < tokens.count &&
                  pos2 + expectedLCP < tokens.count &&
                  tokens[pos1 + expectedLCP] == tokens[pos2 + expectedLCP] {
                expectedLCP += 1
            }

            #expect(lcp.array[i] == expectedLCP,
                   "LCP[\(i)] should be \(expectedLCP) but got \(lcp.array[i])")
        }
    }

    @Test("LCP with no common prefixes")
    func lcpNoCommonPrefixes() {
        let tokens = [5, 4, 3, 2, 1] // Strictly descending
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
        #expect(maxLCP >= 6) // "abcabc" appears twice
    }
}

// MARK: - Integration Tests

@Suite("Suffix Array Integration Tests")
struct SuffixArrayIntegrationTests {

    @Test("End-to-end clone detection")
    func endToEndCloneDetection() {
        // Create two token sequences with a shared pattern
        let sharedPattern = (0..<20).map { TokenInfo(kind: .identifier, text: "shared\($0)", line: $0, column: 0) }

        var tokens1 = [TokenInfo(kind: .identifier, text: "unique1", line: 0, column: 0)]
        tokens1.append(contentsOf: sharedPattern)
        tokens1.append(TokenInfo(kind: .identifier, text: "end1", line: 21, column: 0))

        var tokens2 = [TokenInfo(kind: .identifier, text: "unique2", line: 0, column: 0)]
        tokens2.append(contentsOf: sharedPattern)
        tokens2.append(TokenInfo(kind: .identifier, text: "end2", line: 21, column: 0))

        let seq1 = TokenSequence(file: "file1.swift", tokens: tokens1, sourceLines: [])
        let seq2 = TokenSequence(file: "file2.swift", tokens: tokens2, sourceLines: [])

        let detector = SuffixArrayCloneDetector(minimumTokens: 10)
        let clones = detector.detect(in: [seq1, seq2])

        // Should find at least one clone group
        #expect(!clones.isEmpty)

        // The clone should span the shared pattern
        if let group = clones.first {
            #expect(group.type == CloneType.exact)
            #expect(group.clones.count >= 2)
        }
    }

    @Test("Large scale clone detection performance")
    func largeScalePerformance() {
        // Create 10 sequences with some repeated patterns
        var sequences: [TokenSequence] = []

        for fileIdx in 0..<10 {
            var tokens: [TokenInfo] = []

            // Add some unique tokens
            for i in 0..<100 {
                tokens.append(TokenInfo(
                    kind: .identifier,
                    text: "file\(fileIdx)_token\(i)",
                    line: i,
                    column: 0
                ))
            }

            // Add a shared pattern (same across all files)
            for i in 0..<50 {
                tokens.append(TokenInfo(
                    kind: .identifier,
                    text: "shared_token\(i)",
                    line: 100 + i,
                    column: 0
                ))
            }

            sequences.append(TokenSequence(
                file: "file\(fileIdx).swift",
                tokens: tokens,
                sourceLines: []
            ))
        }

        let detector = SuffixArrayCloneDetector(minimumTokens: 20)

        // This should complete quickly even with large input
        let clones = detector.detect(in: sequences)

        // Should find clones of the shared pattern
        #expect(!clones.isEmpty)
    }
}
