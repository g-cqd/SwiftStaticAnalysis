//
//  ExactCloneDetector.swift
//  SwiftStaticAnalysis
//
//  Detects exact code clones using Rabin-Karp rolling hash algorithm.
//

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - RollingHash

/// Rabin-Karp rolling hash implementation.
struct RollingHash: Sendable {
    // MARK: Lifecycle

    init(windowSize: Int) {
        self.windowSize = windowSize

        // Precompute base^(windowSize-1) mod prime
        var power: UInt64 = 1
        for _ in 0 ..< (windowSize - 1) {
            power = (power &* Self.base) % Self.prime
        }
        highestPower = power
    }

    // MARK: Internal

    /// Compute initial hash for a window of tokens.
    func initialHash(_ tokens: [String]) -> UInt64 {
        var hash: UInt64 = 0
        for token in tokens.prefix(windowSize) {
            hash = (hash &* Self.base &+ tokenHash(token)) % Self.prime
        }
        return hash
    }

    /// Roll the hash forward by removing `outgoing` and adding `incoming`.
    func roll(hash: UInt64, outgoing: String, incoming: String) -> UInt64 {
        let outHash = tokenHash(outgoing)
        let inHash = tokenHash(incoming)

        // Remove outgoing token's contribution
        var newHash = hash
        let outContrib = (outHash &* highestPower) % Self.prime
        if newHash >= outContrib {
            newHash = newHash - outContrib
        } else {
            newHash = Self.prime - (outContrib - newHash)
        }

        // Shift and add incoming
        newHash = ((newHash &* Self.base) + inHash) % Self.prime
        return newHash
    }

    // MARK: Private

    /// Large prime for modulo operations.
    private static let prime: UInt64 = 1_000_000_007

    /// Base for polynomial rolling hash.
    private static let base: UInt64 = 31

    /// Precomputed power of base^windowSize mod prime.
    private let highestPower: UInt64

    /// Window size (number of tokens).
    private let windowSize: Int

    /// Hash a single token string.
    private func tokenHash(_ token: String) -> UInt64 {
        var hash: UInt64 = 0
        for char in token.utf8 {
            hash = (hash &* 31 &+ UInt64(char)) % Self.prime
        }
        return hash
    }
}

// MARK: - TokenWindow

/// A window of tokens with its hash and location.
struct TokenWindow: Sendable, GroupableWindow {
    let file: String
    let hash: UInt64
    let startIndex: Int
    let endIndex: Int
    let startLine: Int
    let endLine: Int
    let tokens: [String]

    func matches(_ other: TokenWindow) -> Bool {
        tokens == other.tokens
    }
}

// MARK: - ExactCloneDetector

/// Detects exact code clones using rolling hash.
public struct ExactCloneDetector: Sendable {
    // MARK: Lifecycle

    public init(minimumTokens: Int = 50) {
        self.minimumTokens = minimumTokens
        extractor = TokenSequenceExtractor()
    }

    // MARK: Public

    /// Minimum number of tokens to consider.
    public let minimumTokens: Int

    /// Detect exact clones across multiple token sequences.
    public func detect(in sequences: [TokenSequence]) -> [CloneGroup] {
        guard minimumTokens > 0 else { return [] }

        // Build hash table of all windows
        var hashTable: [UInt64: [TokenWindow]] = [:]
        let rollingHash = RollingHash(windowSize: minimumTokens)

        for sequence in sequences {
            let windows = extractWindows(from: sequence, rollingHash: rollingHash)
            for window in windows {
                hashTable[window.hash, default: []].append(window)
            }
        }

        // Find groups with hash collisions (potential clones)
        var cloneGroups: [CloneGroup] = []

        for (hash, windows) in hashTable where windows.count >= 2 {
            // Verify actual matches (handle hash collisions)
            let verified = verifyAndGroupClones(windows)
            for group in verified {
                let clones = group.map { window in
                    Clone(
                        file: window.file,
                        startLine: window.startLine,
                        endLine: window.endLine,
                        tokenCount: minimumTokens,
                        codeSnippet: "", // Will be filled in by caller
                    )
                }

                if clones.count >= 2 {
                    cloneGroups.append(CloneGroup(
                        type: .exact,
                        clones: clones,
                        similarity: 1.0,
                        fingerprint: String(hash),
                    ))
                }
            }
        }

        // Deduplicate clone groups
        return cloneGroups.deduplicated()
    }

    // MARK: Private

    /// Token sequence extractor.
    private let extractor: TokenSequenceExtractor

    /// Extract all token windows from a sequence.
    private func extractWindows(
        from sequence: TokenSequence,
        rollingHash: RollingHash,
    ) -> [TokenWindow] {
        guard sequence.tokens.count >= minimumTokens else { return [] }

        var windows: [TokenWindow] = []
        let tokens = sequence.tokens
        let tokenTexts = tokens.map(\.text)

        // Compute initial hash
        var hash = rollingHash.initialHash(Array(tokenTexts.prefix(minimumTokens)))

        // First window
        windows.append(TokenWindow(
            file: sequence.file,
            hash: hash,
            startIndex: 0,
            endIndex: minimumTokens - 1,
            startLine: tokens[0].line,
            endLine: tokens[minimumTokens - 1].line,
            tokens: Array(tokenTexts.prefix(minimumTokens)),
        ))

        // Roll through remaining windows
        let maxStartIndex = tokens.count - minimumTokens
        for i in 1 ... maxStartIndex where maxStartIndex >= 1 {
            let outgoing = tokenTexts[i - 1]
            let incoming = tokenTexts[i + minimumTokens - 1]
            hash = rollingHash.roll(hash: hash, outgoing: outgoing, incoming: incoming)

            windows.append(TokenWindow(
                file: sequence.file,
                hash: hash,
                startIndex: i,
                endIndex: i + minimumTokens - 1,
                startLine: tokens[i].line,
                endLine: tokens[i + minimumTokens - 1].line,
                tokens: Array(tokenTexts[i ..< (i + minimumTokens)]),
            ))
        }

        return windows
    }

    /// Verify hash matches are actual clones (not collisions).
    private func verifyAndGroupClones(_ windows: [TokenWindow]) -> [[TokenWindow]] {
        CloneDetectionUtilities.groupMatchingWindows(windows, overlapThreshold: minimumTokens / 2)
    }
}
