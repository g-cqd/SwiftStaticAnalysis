//
//  SuffixArray.swift
//  SwiftStaticAnalysis
//
//  Suffix Array implementation using the SA-IS (Suffix Array Induced Sorting) algorithm.
//  Achieves O(n) time complexity for construction with excellent cache locality.
//

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
    public static func fromStrings(_ strings: [String]) -> (SuffixArray, [String: Int]) {
        // Build alphabet mapping
        var alphabet: [String: Int] = [:]
        var nextId = 1 // Reserve 0 for sentinel
        for s in strings {
            if alphabet[s] == nil {
                alphabet[s] = nextId
                nextId += 1
            }
        }

        // Convert strings to token IDs
        let tokens = strings.map { alphabet[$0]! }

        return (SuffixArray(tokens: tokens), alphabet)
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
        let alphabetSize = (input.max() ?? 0) + 2 // +1 for max value, +1 for sentinel

        // Append sentinel (smaller than all other characters)
        var text = input
        text.append(0) // Sentinel

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

        // Step 1: Classify each suffix as S-type or L-type
        // S-type: suffix[i] < suffix[i+1] lexicographically
        // L-type: suffix[i] > suffix[i+1] lexicographically
        var types = [Bool](repeating: false, count: n) // true = S-type, false = L-type
        types[n - 1] = true // Last suffix is always S-type (sentinel)

        for i in stride(from: n - 2, through: 0, by: -1) {
            if text[i] < text[i + 1] {
                types[i] = true // S-type
            } else if text[i] > text[i + 1] {
                types[i] = false // L-type
            } else {
                types[i] = types[i + 1] // Same as next
            }
        }

        // Step 2: Find LMS (Leftmost S-type) positions
        // An LMS suffix is an S-type suffix whose predecessor is L-type
        var lmsPositions: [Int] = []
        for i in 1 ..< n {
            if types[i], !types[i - 1] {
                lmsPositions.append(i)
            }
        }

        // Step 3: Get bucket boundaries
        var bucketSizes = [Int](repeating: 0, count: alphabetSize)
        for c in text {
            bucketSizes[c] += 1
        }

        var bucketHeads = [Int](repeating: 0, count: alphabetSize)
        var bucketTails = [Int](repeating: 0, count: alphabetSize)
        var sum = 0
        for i in 0 ..< alphabetSize {
            bucketHeads[i] = sum
            sum += bucketSizes[i]
            bucketTails[i] = sum - 1
        }

        // Step 4: Initial placement of LMS suffixes at bucket tails
        var sa = [Int](repeating: -1, count: n)
        var tails = bucketTails // Working copy

        for i in stride(from: lmsPositions.count - 1, through: 0, by: -1) {
            let pos = lmsPositions[i]
            let c = text[pos]
            sa[tails[c]] = pos
            tails[c] -= 1
        }

        // Step 5: Induced sort L-type suffixes (left to right)
        var heads = bucketHeads // Working copy
        for i in 0 ..< n {
            let j = sa[i] - 1
            if sa[i] > 0, !types[j] { // L-type predecessor
                let c = text[j]
                sa[heads[c]] = j
                heads[c] += 1
            }
        }

        // Step 6: Induced sort S-type suffixes (right to left)
        tails = bucketTails // Reset working copy
        for i in stride(from: n - 1, through: 0, by: -1) {
            let j = sa[i] - 1
            if sa[i] > 0, types[j] { // S-type predecessor
                let c = text[j]
                sa[tails[c]] = j
                tails[c] -= 1
            }
        }

        // Step 7: Extract sorted LMS substrings and assign names
        var lmsNames = [Int](repeating: -1, count: n)
        var name = 0
        var prevLMS = -1

        for i in 0 ..< n {
            let pos = sa[i]
            if pos > 0, types[pos], !types[pos - 1] {
                // This is an LMS suffix
                if prevLMS >= 0, !lmsSubstringsEqual(text: text, types: types, i: prevLMS, j: pos) {
                    name += 1
                }
                lmsNames[pos] = name
                prevLMS = pos
            }
        }

        // Step 8: If all LMS substrings have unique names, we're done
        // Otherwise, recursively sort LMS substrings
        let lmsCount = lmsPositions.count
        if name + 1 < lmsCount {
            // Build reduced string from LMS names
            var reducedString = [Int](repeating: 0, count: lmsCount)
            var j = 0
            for i in 0 ..< n {
                if lmsNames[i] >= 0 {
                    reducedString[j] = lmsNames[i]
                    j += 1
                }
            }

            // Recursively build suffix array of reduced string
            let reducedSA = build(reducedString, alphabetSize: name + 1)

            // Step 9: Use reduced SA to place LMS suffixes in correct order
            sa = [Int](repeating: -1, count: n)
            tails = bucketTails

            for i in stride(from: lmsCount - 1, through: 0, by: -1) {
                let pos = lmsPositions[reducedSA[i]]
                let c = text[pos]
                sa[tails[c]] = pos
                tails[c] -= 1
            }

            // Step 10: Final induced sort
            heads = bucketHeads
            for i in 0 ..< n {
                let j = sa[i] - 1
                if sa[i] > 0, !types[j] {
                    let c = text[j]
                    sa[heads[c]] = j
                    heads[c] += 1
                }
            }

            tails = bucketTails
            for i in stride(from: n - 1, through: 0, by: -1) {
                let j = sa[i] - 1
                if sa[i] > 0, types[j] {
                    let c = text[j]
                    sa[tails[c]] = j
                    tails[c] -= 1
                }
            }
        }

        return sa
    }

    // MARK: Private

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
        var sa = Array(0 ..< n)
        sa.sort { i, j in
            var pi = i
            var pj = j
            while pi < n, pj < n {
                if text[pi] < text[pj] { return true }
                if text[pi] > text[pj] { return false }
                pi += 1
                pj += 1
            }
            return pi >= n // Shorter suffix comes first
        }
        return sa
    }
}

// MARK: - Suffix Array Utilities

public extension SuffixArray {
    /// Binary search for a pattern in the suffix array.
    ///
    /// - Parameters:
    ///   - pattern: The pattern to search for (as token IDs).
    ///   - tokens: The original token array.
    /// - Returns: Range of indices in the suffix array where pattern occurs.
    func search(pattern: [Int], in tokens: [Int]) -> Range<Int>? {
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

        return lower < upper ? lower ..< upper : nil
    }

    /// Compare a suffix with a pattern.
    /// Returns negative if suffix < pattern, 0 if prefix match, positive if suffix > pattern.
    private func compare(suffix start: Int, with pattern: [Int], in tokens: [Int]) -> Int {
        for i in 0 ..< pattern.count {
            let pos = start + i
            if pos >= tokens.count {
                return -1 // Suffix is shorter, so it's "less than"
            }
            if tokens[pos] < pattern[i] {
                return -1
            }
            if tokens[pos] > pattern[i] {
                return 1
            }
        }
        return 0 // Prefix match
    }

    /// Get all occurrences of a pattern.
    func findOccurrences(of pattern: [Int], in tokens: [Int]) -> [Int] {
        guard let range = search(pattern: pattern, in: tokens) else { return [] }
        return (range.lowerBound ..< range.upperBound).map { array[$0] }
    }
}
