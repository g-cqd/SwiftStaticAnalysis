//  SuffixArray.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SuffixArray

/// A suffix array data structure for efficient substring matching.
///
/// The suffix array is an integer array containing the starting indices of all
/// lexicographically sorted suffixes of the input. Combined with the LCP array,
/// it enables linear-time detection of all repeated substrings.
public struct SuffixArray: Sendable {
    // MARK: Lifecycle

    /// Creates a suffix array from an array of integers (token IDs).
    ///
    /// - Parameter tokens: Array of integer token IDs.
    /// - Note: Token IDs should be in range [0, alphabetSize).
    public init(tokens: [Int]) {
        length = tokens.count
        if tokens.isEmpty {
            array = []
        } else {
            array = SuffixArrayBuilder.build(tokens)
        }
    }

    // MARK: Public

    /// The suffix array - indices of sorted suffixes.
    public let array: [Int]

    /// The original input length.
    public let length: Int

    /// Creates a suffix array from an array of strings.
    ///
    /// - Parameter strings: Array of string tokens.
    /// - Returns: The suffix array and the token-to-ID mapping.
    public static func fromStrings(_ strings: [String]) -> (Self, [String: Int]) {
        // Build alphabet mapping and convert to token IDs in one pass
        var alphabet: [String: Int] = [:]
        var tokens: [Int] = []
        tokens.reserveCapacity(strings.count)
        var nextId = 1  // Reserve 0 for sentinel

        for s in strings {
            if let existingId = alphabet[s] {
                tokens.append(existingId)
            } else {
                alphabet[s] = nextId
                tokens.append(nextId)
                nextId += 1
            }
        }

        return (Self(tokens: tokens), alphabet)
    }

    /// Get the suffix starting at the i-th position in sorted order.
    public subscript(i: Int) -> Int {
        array[i]
    }
}

// MARK: - SuffixArrayBuilder

/// Builder for suffix arrays using the SA-IS (Suffix Array Induced Sorting) algorithm.
///
/// SA-IS achieves O(n) time complexity for suffix array construction.
/// Reference: Nong, Zhang, Chan - "Two Efficient Algorithms for Linear Time Suffix Array Construction" (2009)
enum SuffixArrayBuilder {
    /// Build suffix array using SA-IS algorithm.
    static func build(_ input: [Int]) -> [Int] {
        let n = input.count
        guard n > 0 else { return [] }

        // Handle single element
        if n == 1 {
            return [0]
        }

        // Find alphabet size
        let alphabetSize = (input.max() ?? 0) + 2  // +1 for max value, +1 for sentinel

        // Append sentinel (smaller than all other characters)
        var text = input
        text.append(0)  // Sentinel

        // Build suffix array using SA-IS
        let sa = SAIS.build(text, alphabetSize: alphabetSize)

        // Remove sentinel position from result
        return sa.filter { $0 < n }
    }
}

// MARK: - SAIS

/// Implementation of the SA-IS (Suffix Array Induced Sorting) algorithm.
/// Achieves O(n) time complexity for suffix array construction.
enum SAIS {
    // MARK: Internal

    /// Build suffix array using SA-IS algorithm.
    ///
    /// - Parameters:
    ///   - text: Input text as array of integers (must end with unique smallest character).
    ///   - alphabetSize: Size of the alphabet (max value + 1).
    /// - Returns: Suffix array.
    static func build(_ text: [Int], alphabetSize: Int) -> [Int] {
        let n = text.count
        guard n > 1 else { return n == 1 ? [0] : [] }

        // For small inputs, use simple sorting
        if n <= 32 {
            return buildSimple(text)
        }

        // Classify suffixes and find LMS positions
        let types = classifyTypes(text)
        let lmsPositions = findLMSPositions(types)

        // Compute bucket boundaries
        let (bucketHeads, bucketTails) = computeBucketBoundaries(text, alphabetSize: alphabetSize)

        // Initial placement and first round of induced sorting
        var sa = placeLMSSuffixes(text, lmsPositions: lmsPositions, bucketTails: bucketTails)
        inducedSortLType(sa: &sa, text: text, types: types, bucketHeads: bucketHeads)
        inducedSortSType(sa: &sa, text: text, types: types, bucketTails: bucketTails)

        // Assign names to LMS substrings
        let (lmsNames, name) = assignLMSNames(sa: sa, text: text, types: types)

        // If not all LMS substrings have unique names, recursively sort
        let lmsCount = lmsPositions.count
        if name + 1 < lmsCount {
            let reducedString = buildReducedString(lmsNames: lmsNames)
            let reducedSA = build(reducedString, alphabetSize: name + 1)

            // Rebuild SA with correct LMS order
            sa = placeLMSSuffixesOrdered(
                text, lmsPositions: lmsPositions, reducedSA: reducedSA, bucketTails: bucketTails,
            )
            inducedSortLType(sa: &sa, text: text, types: types, bucketHeads: bucketHeads)
            inducedSortSType(sa: &sa, text: text, types: types, bucketTails: bucketTails)
        }

        return sa
    }

    // MARK: Private

    /// Classify each suffix as S-type (true) or L-type (false).
    private static func classifyTypes(_ text: [Int]) -> [Bool] {
        let n = text.count
        var types = [Bool](repeating: false, count: n)
        types[n - 1] = true  // Last suffix is always S-type (sentinel)

        for i in stride(from: n - 2, through: 0, by: -1) {
            if text[i] < text[i + 1] {
                types[i] = true
            } else if text[i] == text[i + 1] {
                types[i] = types[i + 1]
            }
        }
        return types
    }

    /// Find LMS (Leftmost S-type) positions.
    private static func findLMSPositions(_ types: [Bool]) -> [Int] {
        var positions: [Int] = []
        for i in 1..<types.count where types[i] && !types[i - 1] {
            positions.append(i)
        }
        return positions
    }

    /// Compute bucket head and tail positions.
    private static func computeBucketBoundaries(
        _ text: [Int], alphabetSize: Int,
    ) -> (heads: [Int], tails: [Int]) {
        var bucketSizes = [Int](repeating: 0, count: alphabetSize)
        for c in text {
            bucketSizes[c] += 1
        }

        var heads = [Int](repeating: 0, count: alphabetSize)
        var tails = [Int](repeating: 0, count: alphabetSize)
        var sum = 0
        for i in 0..<alphabetSize {
            heads[i] = sum
            sum += bucketSizes[i]
            tails[i] = sum - 1
        }
        return (heads, tails)
    }

    /// Place LMS suffixes at bucket tails.
    private static func placeLMSSuffixes(
        _ text: [Int], lmsPositions: [Int], bucketTails: [Int],
    ) -> [Int] {
        var sa = [Int](repeating: -1, count: text.count)
        var tails = bucketTails
        for i in stride(from: lmsPositions.count - 1, through: 0, by: -1) {
            let pos = lmsPositions[i]
            let c = text[pos]
            sa[tails[c]] = pos
            tails[c] -= 1
        }
        return sa
    }

    /// Place LMS suffixes in order determined by reduced SA.
    private static func placeLMSSuffixesOrdered(
        _ text: [Int], lmsPositions: [Int], reducedSA: [Int], bucketTails: [Int],
    ) -> [Int] {
        var sa = [Int](repeating: -1, count: text.count)
        var tails = bucketTails
        for i in stride(from: lmsPositions.count - 1, through: 0, by: -1) {
            let pos = lmsPositions[reducedSA[i]]
            let c = text[pos]
            sa[tails[c]] = pos
            tails[c] -= 1
        }
        return sa
    }

    /// Induced sort L-type suffixes (left to right).
    private static func inducedSortLType(
        sa: inout [Int], text: [Int], types: [Bool], bucketHeads: [Int],
    ) {
        var heads = bucketHeads
        for i in 0..<sa.count where sa[i] > 0 && !types[sa[i] - 1] {
            let j = sa[i] - 1
            let c = text[j]
            sa[heads[c]] = j
            heads[c] += 1
        }
    }

    /// Induced sort S-type suffixes (right to left).
    private static func inducedSortSType(
        sa: inout [Int], text: [Int], types: [Bool], bucketTails: [Int],
    ) {
        var tails = bucketTails
        for i in stride(from: sa.count - 1, through: 0, by: -1) where sa[i] > 0 && types[sa[i] - 1] {
            let j = sa[i] - 1
            let c = text[j]
            sa[tails[c]] = j
            tails[c] -= 1
        }
    }

    /// Assign names to sorted LMS substrings.
    private static func assignLMSNames(
        sa: [Int], text: [Int], types: [Bool],
    ) -> (names: [Int], maxName: Int) {
        let n = text.count
        var lmsNames = [Int](repeating: -1, count: n)
        var name = 0
        var prevLMS = -1

        for i in 0..<n {
            let pos = sa[i]
            guard pos > 0, types[pos], !types[pos - 1] else { continue }

            if prevLMS >= 0, !lmsSubstringsEqual(text: text, types: types, i: prevLMS, j: pos) {
                name += 1
            }
            lmsNames[pos] = name
            prevLMS = pos
        }

        return (lmsNames, name)
    }

    /// Build reduced string from LMS names.
    private static func buildReducedString(lmsNames: [Int]) -> [Int] {
        lmsNames.filter { $0 >= 0 }
    }

    /// Check if two LMS substrings are equal.
    private static func lmsSubstringsEqual(text: [Int], types: [Bool], i: Int, j: Int) -> Bool {
        let n = text.count
        var pi = i
        var pj = j

        while true {
            if text[pi] != text[pj] {
                return false
            }
            if types[pi] != types[pj] {
                return false
            }

            pi += 1
            pj += 1

            if pi >= n || pj >= n {
                return pi >= n && pj >= n
            }

            // Check if we've reached the end of both LMS substrings
            let endI = pi > 0 && types[pi] && !types[pi - 1]
            let endJ = pj > 0 && types[pj] && !types[pj - 1]

            if endI, endJ {
                return true
            }
            if endI != endJ {
                return false
            }
        }
    }

    /// Simple O(n log n) suffix array for small inputs.
    private static func buildSimple(_ text: [Int]) -> [Int] {
        let n = text.count
        var sa = Array(0..<n)
        sa.sort { i, j in
            var pi = i
            var pj = j
            while pi < n, pj < n {
                if text[pi] < text[pj] { return true }
                if text[pi] > text[pj] { return false }
                pi += 1
                pj += 1
            }
            return pi >= n  // Shorter suffix comes first
        }
        return sa
    }
}

// MARK: - Suffix Array Utilities

extension SuffixArray {
    /// Binary search for a pattern in the suffix array.
    ///
    /// - Parameters:
    ///   - pattern: The pattern to search for (as token IDs).
    ///   - tokens: The original token array.
    /// - Returns: Range of indices in the suffix array where pattern occurs.
    public func search(pattern: [Int], in tokens: [Int]) -> Range<Int>? {
        guard !pattern.isEmpty, !array.isEmpty else { return nil }

        // Find lower bound
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if compare(suffix: array[mid], with: pattern, in: tokens) < 0 {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let lower = lo

        // Find upper bound
        hi = array.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if compare(suffix: array[mid], with: pattern, in: tokens) <= 0 {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let upper = lo

        return lower < upper ? lower..<upper : nil
    }

    /// Compare a suffix with a pattern.
    /// Returns negative if suffix < pattern, 0 if prefix match, positive if suffix > pattern.
    private func compare(suffix start: Int, with pattern: [Int], in tokens: [Int]) -> Int {
        for i in 0..<pattern.count {
            let pos = start + i
            if pos >= tokens.count {
                return -1  // Suffix is shorter, so it's "less than"
            }
            if tokens[pos] < pattern[i] {
                return -1
            }
            if tokens[pos] > pattern[i] {
                return 1
            }
        }
        return 0  // Prefix match
    }

    /// Get all occurrences of a pattern.
    public func findOccurrences(of pattern: [Int], in tokens: [Int]) -> [Int] {
        guard let range = search(pattern: pattern, in: tokens) else { return [] }
        return (range.lowerBound..<range.upperBound).map { array[$0] }
    }
}
