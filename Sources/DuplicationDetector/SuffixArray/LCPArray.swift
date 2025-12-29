//
//  LCPArray.swift
//  SwiftStaticAnalysis
//
//  Longest Common Prefix (LCP) array implementation.
//  The LCP array stores the length of the longest common prefix between
//  consecutive suffixes in the sorted suffix array, enabling O(n) detection
//  of all maximal repeats.
//

import Foundation

// MARK: - LCPArray

/// Longest Common Prefix array for efficient repeat detection.
///
/// The LCP array `lcp[i]` contains the length of the longest common prefix
/// between `suffixArray[i-1]` and `suffixArray[i]`. This enables finding
/// all repeated substrings by scanning for values >= threshold.
public struct LCPArray: Sendable {
    // MARK: Lifecycle

    /// Creates an LCP array from a suffix array and the original tokens.
    ///
    /// Uses Kasai's algorithm for O(n) construction.
    ///
    /// - Parameters:
    ///   - suffixArray: The suffix array.
    ///   - tokens: The original token array (as integers).
    public init(suffixArray: SuffixArray, tokens: [Int]) {
        self.suffixArray = suffixArray
        array = LCPArrayBuilder.build(suffixArray: suffixArray, tokens: tokens)
    }

    // MARK: Public

    /// The LCP values. `lcp[i]` = LCP of SA[i-1] and SA[i]. lcp[0] is always 0.
    public let array: [Int]

    /// The suffix array this LCP array corresponds to.
    public let suffixArray: SuffixArray

    /// Get the LCP value at index i.
    public subscript(i: Int) -> Int {
        array[i]
    }

    /// Find all positions where LCP >= threshold.
    /// These represent repeated substrings of at least `threshold` tokens.
    public func findRepeatsAboveThreshold(_ threshold: Int) -> [Int] {
        var positions: [Int] = []
        for i in 1 ..< array.count {
            if array[i] >= threshold {
                positions.append(i)
            }
        }
        return positions
    }
}

// MARK: - LCPArrayBuilder

/// Builder for LCP arrays using Kasai's algorithm.
///
/// Kasai's algorithm computes the LCP array in O(n) time by exploiting
/// the property that LCP values decrease by at most 1 when moving to
/// the next suffix in text order.
enum LCPArrayBuilder {
    /// Build LCP array using Kasai's algorithm.
    static func build(suffixArray: SuffixArray, tokens: [Int]) -> [Int] {
        let n = tokens.count
        guard n > 0 else { return [] }
        guard suffixArray.array.count == n else { return [] }

        let sa = suffixArray.array

        // Build inverse suffix array (rank array)
        // rank[i] = position of suffix starting at i in the sorted suffix array
        var rank = [Int](repeating: 0, count: n)
        for i in 0 ..< n {
            rank[sa[i]] = i
        }

        // Build LCP array using Kasai's algorithm
        var lcp = [Int](repeating: 0, count: n)
        var h = 0 // Current LCP length

        for i in 0 ..< n {
            let r = rank[i] // Position of suffix[i] in SA

            if r > 0 {
                // Get the suffix that comes just before in sorted order
                let j = sa[r - 1]

                // Compare suffix[i] and suffix[j] starting from position h
                while i + h < n, j + h < n, tokens[i + h] == tokens[j + h] {
                    h += 1
                }

                lcp[r] = h

                // Key insight: LCP can decrease by at most 1
                if h > 0 {
                    h -= 1
                }
            }
        }

        return lcp
    }
}

// MARK: - DetectedRepeat

/// A detected repeat (clone candidate) from LCP array analysis.
public struct DetectedRepeat: Sendable, Hashable {
    // MARK: Lifecycle

    public init(positions: [Int], length: Int) {
        self.positions = positions.sorted()
        self.length = length
    }

    // MARK: Public

    /// Starting positions of all occurrences in the original token array.
    public let positions: [Int]

    /// Length of the repeated substring (in tokens).
    public let length: Int

    /// Number of occurrences.
    public var occurrences: Int { positions.count }
}

extension LCPArray {
    /// Find all maximal repeats of at least `minLength` tokens.
    ///
    /// A maximal repeat is a substring that:
    /// 1. Occurs at least twice
    /// 2. Cannot be extended in either direction without reducing occurrences
    ///
    /// - Parameter minLength: Minimum length of repeats to find.
    /// - Returns: Array of detected repeats.
    public func findMaximalRepeats(minLength: Int) -> [DetectedRepeat] {
        guard array.count > 1 else { return [] }

        var repeats: [DetectedRepeat] = []
        let sa = suffixArray.array

        // Find contiguous regions in LCP array with values >= minLength
        var i = 1
        while i < array.count {
            if array[i] >= minLength {
                // Start of a region
                let regionStart = i - 1
                var regionEnd = i
                var minLcp = array[i]

                // Extend region while LCP stays >= minLength
                while regionEnd + 1 < array.count, array[regionEnd + 1] >= minLength {
                    regionEnd += 1
                    minLcp = min(minLcp, array[regionEnd])
                }

                // Collect all positions in this region
                var positions: [Int] = []
                for j in regionStart ... regionEnd {
                    positions.append(sa[j])
                }

                // The repeat length is the minimum LCP in the region
                if positions.count >= 2 {
                    repeats.append(DetectedRepeat(positions: positions, length: minLcp))
                }

                i = regionEnd + 1
            } else {
                i += 1
            }
        }

        // Merge overlapping repeats and filter to maximal ones
        return filterToMaximalRepeats(repeats, minLength: minLength)
    }

    /// Filter repeats to only include maximal ones.
    private func filterToMaximalRepeats(_ repeats: [DetectedRepeat], minLength: Int) -> [DetectedRepeat] {
        guard !repeats.isEmpty else { return [] }

        // Group by position sets
        var uniqueRepeats: [Set<Int>: DetectedRepeat] = [:]

        for rep in repeats {
            let posSet = Set(rep.positions)

            if let existing = uniqueRepeats[posSet] {
                // Keep the longer one
                if rep.length > existing.length {
                    uniqueRepeats[posSet] = rep
                }
            } else {
                uniqueRepeats[posSet] = rep
            }
        }

        return Array(uniqueRepeats.values)
    }

    /// Find all repeat groups with enhanced position information.
    ///
    /// This groups repeats that share positions into clone groups,
    /// finding the longest common substring for each group.
    ///
    /// - Parameter minLength: Minimum length of repeats to find.
    /// - Returns: Array of repeat groups.
    public func findRepeatGroups(minLength: Int) -> [RepeatGroup] {
        let sa = suffixArray.array
        let n = array.count
        guard n > 1 else { return [] }

        var groups: [RepeatGroup] = []

        // Use a stack-based approach to find all repeat intervals
        // This is more efficient for finding all maximal repeat groups

        var i = 1
        while i < n {
            if array[i] < minLength {
                i += 1
                continue
            }

            // Found start of a repeat region
            var positions: [Int] = [sa[i - 1], sa[i]]
            var minLcp = array[i]
            var j = i + 1

            // Extend while in same or higher LCP region
            while j < n, array[j] >= minLength {
                positions.append(sa[j])
                minLcp = min(minLcp, array[j])
                j += 1
            }

            // Create group with the minimum LCP as the shared length
            let group = RepeatGroup(
                positions: positions,
                length: minLcp,
                suffixArrayIndices: Array((i - 1) ..< j),
            )
            groups.append(group)

            i = j
        }

        return mergeOverlappingGroups(groups)
    }

    /// Merge groups that represent the same underlying repeat.
    private func mergeOverlappingGroups(_ groups: [RepeatGroup]) -> [RepeatGroup] {
        guard !groups.isEmpty else { return [] }

        // Sort by length descending to prefer longer repeats
        let sorted = groups.sorted { $0.length > $1.length }

        var result: [RepeatGroup] = []
        var usedPositions: Set<Int> = []

        for group in sorted {
            // Check if this group's positions overlap significantly with used positions
            let groupPositions = Set(group.positions)
            let overlapCount = groupPositions.intersection(usedPositions).count

            // If less than half overlap, it's a distinct group
            if overlapCount < groupPositions.count / 2 {
                result.append(group)
                usedPositions.formUnion(groupPositions)
            }
        }

        return result
    }
}

// MARK: - RepeatGroup

/// A group of positions sharing a common repeated substring.
public struct RepeatGroup: Sendable {
    // MARK: Lifecycle

    public init(positions: [Int], length: Int, suffixArrayIndices: [Int]) {
        self.positions = positions.sorted()
        self.length = length
        self.suffixArrayIndices = suffixArrayIndices
    }

    // MARK: Public

    /// Starting positions of all occurrences.
    public let positions: [Int]

    /// Length of the common repeated substring.
    public let length: Int

    /// Indices in the suffix array where these positions appear.
    public let suffixArrayIndices: [Int]

    /// Number of occurrences.
    public var occurrences: Int { positions.count }
}
