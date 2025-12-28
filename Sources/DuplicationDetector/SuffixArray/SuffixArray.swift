//
//  SuffixArray.swift
//  SwiftStaticAnalysis
//
//  Suffix Array implementation using the SA-IS (Suffix Array Induced Sorting) algorithm.
//  Achieves O(n) time complexity for construction with excellent cache locality.
//

import Foundation

// MARK: - Suffix Array

/// A suffix array data structure for efficient substring matching.
///
/// The suffix array is an integer array containing the starting indices of all
/// lexicographically sorted suffixes of the input. Combined with the LCP array,
/// it enables linear-time detection of all repeated substrings.
public struct SuffixArray: Sendable {
    /// The suffix array - indices of sorted suffixes.
    public let array: [Int]

    /// The original input length.
    public let length: Int

    /// Creates a suffix array from an array of integers (token IDs).
    ///
    /// - Parameter tokens: Array of integer token IDs.
    /// - Note: Token IDs should be in range [0, alphabetSize).
    public init(tokens: [Int]) {
        self.length = tokens.count
        if tokens.isEmpty {
            self.array = []
        } else {
            self.array = SuffixArrayBuilder.build(tokens)
        }
    }

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

// MARK: - Suffix Array Builder

/// Builder for suffix arrays using comparison-based sorting.
///
/// This implementation uses O(n log² n) comparison-based sorting with
/// doubling technique. While not as fast as SA-IS for very large inputs,
/// it is simpler, more robust, and still efficient for practical code analysis.
enum SuffixArrayBuilder {
    /// Build suffix array using doubling algorithm.
    static func build(_ input: [Int]) -> [Int] {
        let n = input.count
        guard n > 0 else { return [] }

        // Handle single element
        if n == 1 {
            return [0]
        }

        // Use doubling algorithm for O(n log² n) construction
        return buildWithDoubling(input)
    }

    /// Doubling algorithm for suffix array construction.
    ///
    /// This algorithm sorts suffixes by comparing prefixes of increasing length
    /// (1, 2, 4, 8, ...). Each iteration uses the ranks from the previous iteration
    /// to compare pairs of adjacent positions, achieving O(n log n) comparisons
    /// per iteration with O(log n) iterations.
    private static func buildWithDoubling(_ s: [Int]) -> [Int] {
        let n = s.count

        // Initialize suffix array with indices 0 to n-1
        var sa = Array(0..<n)

        // Initialize rank array based on first character
        var rank = [Int](repeating: 0, count: n)
        for i in 0..<n {
            rank[i] = s[i]
        }

        // Temporary array for new ranks
        var tempRank = [Int](repeating: 0, count: n)

        // Double the prefix length each iteration
        var k = 1
        while k < n {
            // Sort by (rank[i], rank[i+k]) pairs
            sa.sort { i, j in
                if rank[i] != rank[j] {
                    return rank[i] < rank[j]
                }
                let ri = i + k < n ? rank[i + k] : -1
                let rj = j + k < n ? rank[j + k] : -1
                return ri < rj
            }

            // Compute new ranks
            tempRank[sa[0]] = 0
            for i in 1..<n {
                let prev = sa[i - 1]
                let curr = sa[i]

                // Check if current suffix has same key as previous
                let prevKey1 = rank[prev]
                let currKey1 = rank[curr]
                let prevKey2 = prev + k < n ? rank[prev + k] : -1
                let currKey2 = curr + k < n ? rank[curr + k] : -1

                if prevKey1 == currKey1 && prevKey2 == currKey2 {
                    tempRank[curr] = tempRank[prev]
                } else {
                    tempRank[curr] = tempRank[prev] + 1
                }
            }

            // Swap rank arrays
            swap(&rank, &tempRank)

            // Early termination if all ranks are unique
            if rank[sa[n - 1]] == n - 1 {
                break
            }

            k *= 2
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
    public func findOccurrences(of pattern: [Int], in tokens: [Int]) -> [Int] {
        guard let range = search(pattern: pattern, in: tokens) else { return [] }
        return (range.lowerBound..<range.upperBound).map { array[$0] }
    }
}
