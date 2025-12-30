//
//  NearCloneDetector.swift
//  SwiftStaticAnalysis
//
//  Detects near-clones (Type 2 clones) where identifiers and literals
//  may be renamed but structure is identical.
//

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - NormalizedWindow

/// A window of normalized tokens with its hash.
struct NormalizedWindow: Sendable, GroupableWindow {
    let file: String
    let hash: UInt64
    let startIndex: Int
    let endIndex: Int
    let startLine: Int
    let endLine: Int
    let normalizedTokens: [String]
    let originalTokens: [String]

    func matches(_ other: Self) -> Bool {
        normalizedTokens == other.normalizedTokens
    }
}

// MARK: - NearCloneDetector

/// Detects near-clones using normalized token comparison.
public struct NearCloneDetector: Sendable {
    // MARK: Lifecycle

    public init(
        minimumTokens: Int = 50,
        minimumSimilarity: Double = 0.8,
    ) {
        self.minimumTokens = minimumTokens
        self.minimumSimilarity = minimumSimilarity
        normalizer = .default
    }

    // MARK: Public

    /// Minimum number of tokens to consider.
    public let minimumTokens: Int

    /// Minimum similarity threshold (0.0 to 1.0).
    public let minimumSimilarity: Double

    /// Detect near-clones across multiple token sequences.
    public func detect(in sequences: [TokenSequence]) -> [CloneGroup] {
        guard minimumTokens > 0 else { return [] }

        // Normalize all sequences
        let normalizedSequences = sequences.map { normalizer.normalize($0) }

        // Build hash table of normalized windows
        var hashTable: [UInt64: [NormalizedWindow]] = [:]
        let rollingHash = RollingHash(windowSize: minimumTokens)

        for sequence in normalizedSequences {
            let windows = extractNormalizedWindows(from: sequence, rollingHash: rollingHash)
            for window in windows {
                hashTable[window.hash, default: []].append(window)
            }
        }

        // Find groups with matching normalized tokens
        var cloneGroups: [CloneGroup] = []

        for (hash, windows) in hashTable where windows.count >= 2 {
            let verified = verifyAndGroupNearClones(windows)
            for group in verified {
                let clones = group.map { window in
                    Clone(
                        file: window.file,
                        startLine: window.startLine,
                        endLine: window.endLine,
                        tokenCount: minimumTokens,
                        codeSnippet: "",
                    )
                }

                if clones.count >= 2 {
                    // Calculate similarity based on original tokens
                    let similarity = calculateGroupSimilarity(group)

                    if similarity >= minimumSimilarity {
                        cloneGroups.append(
                            CloneGroup(
                                type: .near,
                                clones: clones,
                                similarity: similarity,
                                fingerprint: String(hash),
                            ))
                    }
                }
            }
        }

        return cloneGroups.deduplicated()
    }

    // MARK: Private

    /// Token normalizer.
    private let normalizer: TokenNormalizer

    /// Extract normalized windows from a sequence.
    private func extractNormalizedWindows(
        from sequence: NormalizedSequence,
        rollingHash: RollingHash,
    ) -> [NormalizedWindow] {
        // Safety: ensure minimumTokens is valid and sequence has enough tokens
        guard minimumTokens > 0, sequence.tokens.count >= minimumTokens else { return [] }

        var windows: [NormalizedWindow] = []
        let tokens = sequence.tokens
        let normalizedTexts = tokens.map(\.normalized)
        let originalTexts = tokens.map(\.original)

        // Compute initial hash of normalized tokens
        var hash = rollingHash.initialHash(Array(normalizedTexts.prefix(minimumTokens)))

        // First window
        windows.append(
            NormalizedWindow(
                file: sequence.file,
                hash: hash,
                startIndex: 0,
                endIndex: minimumTokens - 1,
                startLine: tokens[0].line,
                endLine: tokens[minimumTokens - 1].line,
                normalizedTokens: Array(normalizedTexts.prefix(minimumTokens)),
                originalTokens: Array(originalTexts.prefix(minimumTokens)),
            ))

        // Roll through remaining windows
        let maxStartIndex = tokens.count - minimumTokens
        guard maxStartIndex >= 1 else { return windows }
        for i in 1...maxStartIndex {
            let outgoing = normalizedTexts[i - 1]
            let incoming = normalizedTexts[i + minimumTokens - 1]
            hash = rollingHash.roll(hash: hash, outgoing: outgoing, incoming: incoming)

            windows.append(
                NormalizedWindow(
                    file: sequence.file,
                    hash: hash,
                    startIndex: i,
                    endIndex: i + minimumTokens - 1,
                    startLine: tokens[i].line,
                    endLine: tokens[i + minimumTokens - 1].line,
                    normalizedTokens: Array(normalizedTexts[i..<(i + minimumTokens)]),
                    originalTokens: Array(originalTexts[i..<(i + minimumTokens)]),
                ))
        }

        return windows
    }

    /// Verify normalized matches and group them.
    private func verifyAndGroupNearClones(_ windows: [NormalizedWindow]) -> [[NormalizedWindow]] {
        CloneDetectionUtilities.groupMatchingWindows(windows, overlapThreshold: minimumTokens / 2)
    }

    /// Calculate similarity for a group based on original tokens.
    private func calculateGroupSimilarity(_ group: [NormalizedWindow]) -> Double {
        guard group.count >= 2 else { return 0 }

        // Compare each pair and average
        var totalSimilarity = 0.0
        var comparisons = 0

        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                totalSimilarity += CloneDetectionUtilities.jaccardSimilarity(
                    group[i].originalTokens,
                    group[j].originalTokens,
                )
                comparisons += 1
            }
        }

        return comparisons > 0 ? totalSimilarity / Double(comparisons) : 0
    }
}
