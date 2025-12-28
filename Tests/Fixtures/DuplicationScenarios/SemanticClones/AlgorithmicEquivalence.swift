//
//  AlgorithmicEquivalence.swift
//  SwiftStaticAnalysis - Test Fixtures
//
//  This file contains semantic clones (Type-3/Type-4).
//  Same algorithms implemented with different syntax.
//

import Foundation

// MARK: - Sum of Squares (Semantic Clones)

/// Imperative style - SEMANTIC CLONE 1
func sumSquaresLoop(_ nums: [Int]) -> Int {
    var sum = 0
    for n in nums {
        sum += n * n
    }
    return sum
}

/// Functional style - SEMANTIC CLONE 2
func sumSquaresFunctional(_ nums: [Int]) -> Int {
    nums.map { $0 * $0 }.reduce(0, +)
}

/// While loop style - SEMANTIC CLONE 3
func sumSquaresWhile(_ nums: [Int]) -> Int {
    var sum = 0
    var index = 0
    while index < nums.count {
        let n = nums[index]
        sum = sum + n * n
        index += 1
    }
    return sum
}

/// Recursive style - SEMANTIC CLONE 4
func sumSquaresRecursive(_ nums: [Int]) -> Int {
    guard let first = nums.first else { return 0 }
    return first * first + sumSquaresRecursive(Array(nums.dropFirst()))
}

// MARK: - Find Maximum (Semantic Clones)

/// Imperative style - SEMANTIC CLONE A
func findMaxLoop(_ nums: [Int]) -> Int? {
    guard !nums.isEmpty else { return nil }
    var maxValue = nums[0]
    for num in nums {
        if num > maxValue {
            maxValue = num
        }
    }
    return maxValue
}

/// Functional style - SEMANTIC CLONE B
func findMaxFunctional(_ nums: [Int]) -> Int? {
    nums.max()
}

/// Reduce style - SEMANTIC CLONE C
func findMaxReduce(_ nums: [Int]) -> Int? {
    guard let first = nums.first else { return nil }
    return nums.reduce(first) { max($0, $1) }
}

// MARK: - Filter Even Numbers (Semantic Clones)

/// Imperative style - SEMANTIC CLONE X
func filterEvenLoop(_ nums: [Int]) -> [Int] {
    var result: [Int] = []
    for num in nums {
        if num % 2 == 0 {
            result.append(num)
        }
    }
    return result
}

/// Functional style - SEMANTIC CLONE Y
func filterEvenFunctional(_ nums: [Int]) -> [Int] {
    nums.filter { $0 % 2 == 0 }
}

/// CompactMap style - SEMANTIC CLONE Z
func filterEvenCompactMap(_ nums: [Int]) -> [Int] {
    nums.compactMap { $0 % 2 == 0 ? $0 : nil }
}

// MARK: - String Reversal (Semantic Clones)

/// Using reversed() - SEMANTIC CLONE S1
func reverseStringBuiltin(_ str: String) -> String {
    String(str.reversed())
}

/// Manual loop - SEMANTIC CLONE S2
func reverseStringLoop(_ str: String) -> String {
    var result = ""
    for char in str {
        result = String(char) + result
    }
    return result
}

/// Reduce style - SEMANTIC CLONE S3
func reverseStringReduce(_ str: String) -> String {
    str.reduce("") { String($1) + $0 }
}

// MARK: - Unique Code (No Semantic Clones)

/// Binary search has no semantic equivalent in this file
func binarySearch(_ nums: [Int], target: Int) -> Int? {
    var left = 0
    var right = nums.count - 1

    while left <= right {
        let mid = left + (right - left) / 2
        if nums[mid] == target {
            return mid
        } else if nums[mid] < target {
            left = mid + 1
        } else {
            right = mid - 1
        }
    }
    return nil
}
