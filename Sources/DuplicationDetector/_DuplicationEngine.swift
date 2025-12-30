//
//  DuplicationEngine.swift
//  SwiftStaticAnalysis
//
//  Shared engine for code duplication detection algorithms.
//

import Foundation
import SwiftStaticAnalysisCore

/// Shared engine for executing duplication detection algorithms and processing results.
struct DuplicationEngine: Sendable {
    /// Configuration for detection.
    let configuration: DuplicationConfiguration

    /// Concurrency configuration.
    let concurrency: ConcurrencyConfiguration

    /// Detect clones in the provided token sequences based on configuration.
    /// Supports .exact and .near clone types.
    func detectClones(in sequences: [TokenSequence]) -> [CloneGroup] {
        var cloneGroups: [CloneGroup] = []

        if configuration.cloneTypes.contains(.exact) {
            switch configuration.algorithm {
            case .minHashLSH,
                .rollingHash:
                // Rolling hash detection (minHashLSH uses this for Type-1 clones)
                let detector = ExactCloneDetector(minimumTokens: configuration.minimumTokens)
                cloneGroups.append(contentsOf: detector.detect(in: sequences))

            case .suffixArray:
                // High-performance suffix array detection
                let detector = SuffixArrayCloneDetector(
                    minimumTokens: configuration.minimumTokens,
                    normalizeForType2: false,
                )
                cloneGroups.append(contentsOf: detector.detect(in: sequences))
            }
        }

        if configuration.cloneTypes.contains(.near) {
            switch configuration.algorithm {
            case .minHashLSH,
                .rollingHash:
                // Near clone detection (minHashLSH uses this for Type-2 clones)
                let detector = NearCloneDetector(
                    minimumTokens: configuration.minimumTokens,
                    minimumSimilarity: configuration.minimumSimilarity,
                )
                cloneGroups.append(contentsOf: detector.detect(in: sequences))

            case .suffixArray:
                // Suffix array with normalized tokens for Type-2 detection
                let detector = SuffixArrayCloneDetector(
                    minimumTokens: configuration.minimumTokens,
                    normalizeForType2: true,
                )
                cloneGroups.append(contentsOf: detector.detectWithNormalization(in: sequences))
            }
        }

        return cloneGroups
    }

    /// Add code snippets to clone groups by reading source files.
    func addCodeSnippets(to groups: [CloneGroup]) async throws -> [CloneGroup] {
        // Collect unique files referenced in clones
        let referencedFiles = Set(groups.flatMap { $0.clones.map(\.file) })

        // Load file contents in parallel
        let fileContentPairs = try await ParallelProcessor.map(
            Array(referencedFiles),
            maxConcurrency: concurrency.maxConcurrentFiles,
        ) { file -> (String, [String]) in
            let source = try String(contentsOfFile: file, encoding: .utf8)
            return (file, source.components(separatedBy: .newlines))
        }

        // Build lookup dictionary
        let fileContents = Dictionary(uniqueKeysWithValues: fileContentPairs)

        return groups.map { group in
            let clonesWithSnippets = group.clones.map { clone in
                let snippet: String
                if let lines = fileContents[clone.file] {
                    let start = max(0, clone.startLine - 1)
                    let end = min(lines.count, clone.endLine)
                    if start < end {
                        snippet = lines[start..<end].joined(separator: "\n")
                    } else {
                        snippet = ""
                    }
                } else {
                    snippet = ""
                }

                return Clone(
                    file: clone.file,
                    startLine: clone.startLine,
                    endLine: clone.endLine,
                    tokenCount: clone.tokenCount,
                    codeSnippet: snippet,
                )
            }

            return CloneGroup(
                type: group.type,
                clones: clonesWithSnippets,
                similarity: group.similarity,
                fingerprint: group.fingerprint,
            )
        }
    }
}
