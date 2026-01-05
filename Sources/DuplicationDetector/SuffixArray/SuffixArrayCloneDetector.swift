//  SuffixArrayCloneDetector.swift
//  SwiftStaticAnalysis
//  MIT License

import Algorithms
import Foundation
import SwiftStaticAnalysisCore

// MARK: - TokenAccessorResult

/// Result from the token accessor closure.
struct TokenAccessorResult: Sendable {
    let text: String
    let original: String
    let line: Int
    let column: Int
}

// MARK: - TokenStreamResult

/// Result of building a concatenated token stream.
struct TokenStreamResult: Sendable {
    let tokens: [Int]
    let infos: [TokenStreamInfo]
}

// MARK: - SuffixArrayCloneDetector

/// Detects code clones using suffix array and LCP array analysis.
///
/// This detector provides deterministic, exhaustive detection of repeated
/// code sequences. Unlike hash-based approaches, it cannot produce false
/// positives and finds ALL repeats above the minimum threshold.
public struct SuffixArrayCloneDetector: Sendable {
    // MARK: Lifecycle

    public init(minimumTokens: Int = 50, normalizeForType2: Bool = false) {
        self.minimumTokens = minimumTokens
        self.normalizeForType2 = normalizeForType2
        normalizer = .default
    }

    // MARK: Public

    /// Minimum number of tokens to consider as a clone.
    public let minimumTokens: Int

    /// Whether to normalize tokens for Type-2 detection.
    public let normalizeForType2: Bool

    /// Detect clones across multiple token sequences.
    ///
    /// - Parameter sequences: Token sequences from parsed files.
    /// - Returns: Array of detected clone groups.
    public func detect(in sequences: [TokenSequence]) -> [CloneGroup] {
        // Safety: ensure minimumTokens is valid
        guard !sequences.isEmpty, minimumTokens > 0 else { return [] }

        // Build concatenated token stream with file boundaries
        let streamResult = buildConcatenatedStream(sequences)

        guard streamResult.tokens.count >= minimumTokens else { return [] }

        // Build suffix array
        let suffixArray = SuffixArray(tokens: streamResult.tokens)

        // Build LCP array
        let lcpArray = LCPArray(suffixArray: suffixArray, tokens: streamResult.tokens)

        // Find repeat groups
        let repeatGroups = lcpArray.findRepeatGroups(minLength: minimumTokens)

        // Convert to clone groups with location information
        return convertToCloneGroups(
            repeatGroups: repeatGroups,
            tokenInfos: streamResult.infos,
            sequences: sequences,
        )
    }

    /// Detect clones with normalized tokens for Type-2 detection.
    ///
    /// - Parameter sequences: Token sequences from parsed files.
    /// - Returns: Array of detected clone groups (both exact and parameterized).
    public func detectWithNormalization(in sequences: [TokenSequence]) -> [CloneGroup] {
        // Safety: ensure minimumTokens is valid
        guard !sequences.isEmpty, minimumTokens > 0 else { return [] }

        // Normalize sequences
        let normalizedSequences = sequences.map { normalizer.normalize($0) }

        // Build concatenated stream from normalized tokens
        let streamResult = buildNormalizedStream(normalizedSequences)

        guard streamResult.tokens.count >= minimumTokens else { return [] }

        // Build suffix array
        let suffixArray = SuffixArray(tokens: streamResult.tokens)

        // Build LCP array
        let lcpArray = LCPArray(suffixArray: suffixArray, tokens: streamResult.tokens)

        // Find repeat groups
        let repeatGroups = lcpArray.findRepeatGroups(minLength: minimumTokens)

        // Convert to clone groups
        return convertNormalizedToCloneGroups(
            repeatGroups: repeatGroups,
            tokenInfos: streamResult.infos,
            sequences: normalizedSequences,
        )
    }

    // MARK: Private

    /// Token normalizer for Type-2 detection.
    private let normalizer: TokenNormalizer

    // MARK: - Stream Building

    /// Build a concatenated token stream from multiple sequences.
    ///
    /// Tokens are converted to integers, and sentinel values are inserted
    /// between files to prevent cross-file matches.
    private func buildConcatenatedStream(_ sequences: [TokenSequence]) -> TokenStreamResult {
        buildStream(from: sequences) { seq, index in
            let token = seq.tokens[index]
            return TokenAccessorResult(text: token.text, original: token.text, line: token.line, column: token.column)
        }
    }

    /// Build concatenated stream from normalized sequences.
    private func buildNormalizedStream(_ sequences: [NormalizedSequence]) -> TokenStreamResult {
        buildStream(from: sequences) { seq, index in
            let token = seq.tokens[index]
            return TokenAccessorResult(
                text: token.normalized,
                original: token.original,
                line: token.line,
                column: token.column,
            )
        }
    }

    /// Generic stream building helper.
    private func buildStream<S: Collection>(
        from sequences: S,
        tokenAccessor: (S.Element, Int) -> TokenAccessorResult,
    ) -> TokenStreamResult where S.Element: TokenSequenceProtocol {
        var tokens: [Int] = []
        var infos: [TokenStreamInfo] = []
        var tokenIdMap: [String: Int] = [:]
        var nextTokenId = 1  // 0 reserved for separators

        for (fileIndex, sequence) in sequences.enumerated() {
            for tokenIdx in 0..<sequence.tokenCount {
                let accessor = tokenAccessor(sequence, tokenIdx)
                let tokenId: Int
                if let existingId = tokenIdMap[accessor.text] {
                    tokenId = existingId
                } else {
                    tokenId = nextTokenId
                    tokenIdMap[accessor.text] = tokenId
                    nextTokenId += 1
                }

                tokens.append(tokenId)
                infos.append(
                    TokenStreamInfo(
                        fileIndex: fileIndex,
                        line: accessor.line,
                        column: accessor.column,
                        originalText: accessor.original
                    ))
            }

            // Add separator between files (unique sentinel)
            let separatorId = nextTokenId
            nextTokenId += 1
            tokens.append(separatorId)
            infos.append(
                TokenStreamInfo(
                    fileIndex: fileIndex,
                    line: -1,
                    column: -1,
                    originalText: "<SEP>"
                ))
        }

        return TokenStreamResult(tokens: tokens, infos: infos)
    }

    // MARK: - Clone Group Conversion

    /// Convert repeat groups to clone groups with full location information.
    private func convertToCloneGroups(
        repeatGroups: [RepeatGroup],
        tokenInfos: [TokenStreamInfo],
        sequences: [TokenSequence],
    ) -> [CloneGroup] {
        buildCloneGroups(
            repeatGroups: repeatGroups,
            tokenInfos: tokenInfos,
            cloneType: .exact,
        ) { pos, length in
            createCloneLocation(
                position: pos,
                length: length,
                tokenInfos: tokenInfos,
                sequences: sequences,
            )
        }
    }

    /// Convert normalized repeat groups to clone groups.
    private func convertNormalizedToCloneGroups(
        repeatGroups: [RepeatGroup],
        tokenInfos: [TokenStreamInfo],
        sequences: [NormalizedSequence],
    ) -> [CloneGroup] {
        buildCloneGroups(
            repeatGroups: repeatGroups,
            tokenInfos: tokenInfos,
            cloneType: .near,
        ) { pos, length in
            createCloneLocation(
                position: pos,
                length: length,
                tokenInfos: tokenInfos,
                sequences: sequences
            )
        }
    }

    /// Common clone group building logic.
    private func buildCloneGroups(
        repeatGroups: [RepeatGroup],
        tokenInfos: [TokenStreamInfo],
        cloneType: CloneType,
        locationCreator: (Int, Int) -> CloneLocation?,
    ) -> [CloneGroup] {
        var cloneGroups: [CloneGroup] = []

        for group in repeatGroups {
            let validPositions = group.positions.filter { pos in
                isValidPosition(pos, length: group.length, tokenInfos: tokenInfos)
            }

            guard validPositions.count >= 2 else { continue }

            let cloneLocations = validPositions.compactMap { pos in
                locationCreator(pos, group.length)
            }

            let filteredLocations = filterOverlappingClones(cloneLocations)

            guard filteredLocations.count >= 2 else { continue }

            let clones = filteredLocations.map { loc in
                Clone(
                    file: loc.file,
                    startLine: loc.startLine,
                    endLine: loc.endLine,
                    tokenCount: group.length,
                    codeSnippet: "",
                )
            }

            let fingerprint = generateFingerprint(
                position: validPositions[0],
                length: min(group.length, 20),
                tokenInfos: tokenInfos,
            )

            cloneGroups.append(
                CloneGroup(
                    type: cloneType,
                    clones: clones,
                    similarity: 1.0,
                    fingerprint: fingerprint,
                ))
        }

        return deduplicateGroups(cloneGroups)
    }

    // MARK: - Helper Methods

    /// Check if a position is valid (doesn't cross file boundaries).
    private func isValidPosition(_ pos: Int, length: Int, tokenInfos: [TokenStreamInfo]) -> Bool {
        guard pos >= 0, pos + length <= tokenInfos.count else { return false }

        let startInfo = tokenInfos[pos]
        let endInfo = tokenInfos[pos + length - 1]

        // Check if start and end are in the same file
        return startInfo.fileIndex == endInfo.fileIndex && startInfo.line >= 0
    }

    /// Create a clone location from a position.
    ///
    /// Generic over any sequence type conforming to TokenSequenceProtocol,
    /// eliminating duplication between regular and normalized sequence handling.
    private func createCloneLocation<S: TokenSequenceProtocol>(
        position: Int,
        length: Int,
        tokenInfos: [TokenStreamInfo],
        sequences: [S]
    ) -> CloneLocation? {
        guard isValidPosition(position, length: length, tokenInfos: tokenInfos) else { return nil }

        let startInfo = tokenInfos[position]
        let endInfo = tokenInfos[position + length - 1]
        let file = sequences[startInfo.fileIndex].file

        return CloneLocation(
            file: file,
            fileIndex: startInfo.fileIndex,
            startLine: startInfo.line,
            endLine: endInfo.line,
            startPosition: position,
            endPosition: position + length - 1
        )
    }

    /// Filter overlapping clones within the same file.
    private func filterOverlappingClones(_ locations: [CloneLocation]) -> [CloneLocation] {
        guard locations.count > 1 else { return locations }

        // Sort by file then start position
        let sorted = locations.sorted { lhs, rhs in
            if lhs.fileIndex != rhs.fileIndex {
                return lhs.fileIndex < rhs.fileIndex
            }
            return lhs.startPosition < rhs.startPosition
        }

        var result: [CloneLocation] = []
        var lastByFile: [Int: CloneLocation] = [:]

        for loc in sorted {
            if let last = lastByFile[loc.fileIndex] {
                // Check for significant overlap (more than 50%)
                let overlapStart = max(last.startPosition, loc.startPosition)
                let overlapEnd = min(last.endPosition, loc.endPosition)
                let overlapLength = max(0, overlapEnd - overlapStart + 1)
                let locLength = loc.endPosition - loc.startPosition + 1

                if overlapLength > locLength / 2 {
                    // Significant overlap, skip this one
                    continue
                }
            }

            result.append(loc)
            lastByFile[loc.fileIndex] = loc
        }

        return result
    }

    /// Generate a fingerprint for a clone.
    private func generateFingerprint(
        position: Int,
        length: Int,
        tokenInfos: [TokenStreamInfo],
    ) -> String {
        var parts: [String] = []
        for i in position..<min(position + length, tokenInfos.count) {
            parts.append(tokenInfos[i].originalText)
        }
        return parts.joined(separator: " ").hashValue.description
    }

    /// Deduplicate clone groups with same locations.
    private func deduplicateGroups(_ groups: [CloneGroup]) -> [CloneGroup] {
        Array(
            groups.uniqued(on: { group in
                group.clones
                    .map { "\($0.file):\($0.startLine)-\($0.endLine)" }
                    .sorted()
                    .joined(separator: "|")
            }))
    }
}

// MARK: - TokenStreamInfo

/// Information about a token in the concatenated stream.
struct TokenStreamInfo: Sendable {
    let fileIndex: Int
    let line: Int
    let column: Int
    let originalText: String
}

// MARK: - CloneLocation

/// Location of a clone occurrence.
struct CloneLocation: Sendable {
    let file: String
    let fileIndex: Int
    let startLine: Int
    let endLine: Int
    let startPosition: Int
    let endPosition: Int
}
