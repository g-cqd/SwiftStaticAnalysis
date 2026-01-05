//
//  DuplicationDetector.swift
//  SwiftStaticAnalysis
//
//  Code duplication detection module.
//

import Algorithms
import Foundation
import SwiftStaticAnalysisCore

// MARK: - CloneType

/// Types of code clones.
public enum CloneType: String, Sendable, Codable, CaseIterable {
    /// Exact clones - identical code except whitespace/comments.
    case exact

    /// Near clones - similar code with renamed identifiers.
    case near

    /// Semantic clones - functionally equivalent but structurally different.
    case semantic
}

// MARK: - Clone

/// Represents a detected code clone.
public struct Clone: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        file: String,
        startLine: Int,
        endLine: Int,
        tokenCount: Int,
        codeSnippet: String,
    ) {
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.tokenCount = tokenCount
        self.codeSnippet = codeSnippet
    }

    // MARK: Public

    /// File containing the clone.
    public let file: String

    /// Starting line number.
    public let startLine: Int

    /// Ending line number.
    public let endLine: Int

    /// Number of tokens in the clone.
    public let tokenCount: Int

    /// The actual code snippet.
    public let codeSnippet: String
}

// MARK: - CloneGroup

/// A group of related clones.
public struct CloneGroup: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        type: CloneType,
        clones: [Clone],
        similarity: Double,
        fingerprint: String,
    ) {
        self.type = type
        self.clones = clones
        self.similarity = similarity
        self.fingerprint = fingerprint
    }

    // MARK: Public

    /// Type of clone.
    public let type: CloneType

    /// Clones in this group.
    public let clones: [Clone]

    /// Similarity score (1.0 for exact, lower for near/semantic).
    public let similarity: Double

    /// Hash or fingerprint identifying this clone group.
    public let fingerprint: String

    /// Number of occurrences.
    public var occurrences: Int { clones.count }

    /// Total duplicated lines.
    public var duplicatedLines: Int {
        clones.reduce(0) { $0 + ($1.endLine - $1.startLine + 1) }
    }
}

// MARK: - DetectionAlgorithm

/// Algorithm used for clone detection.
public enum DetectionAlgorithm: String, Sendable, Codable {
    /// Rolling hash (Rabin-Karp) - fast, may have false positives.
    case rollingHash

    /// Suffix array (SA-IS) - deterministic, exhaustive, no false positives.
    case suffixArray

    /// MinHash + LSH - probabilistic, O(n) complexity for Type-3 clones.
    case minHashLSH
}

// MARK: - DuplicationConfiguration

/// Configuration for duplication detection.
public struct DuplicationConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        minimumTokens: Int = 50,
        cloneTypes: Set<CloneType> = [.exact],
        ignoredPatterns: [String] = [],
        minimumSimilarity: Double = 0.8,
        algorithm: DetectionAlgorithm = .rollingHash,
        useIncremental: Bool = false,
        cacheDirectory: URL? = nil,
        useParallelClones: Bool = false
    ) {
        // Validate and clamp minimumTokens to safe range [1, 10000]
        self.minimumTokens = min(max(minimumTokens, 1), 10000)
        self.cloneTypes = cloneTypes
        self.ignoredPatterns = ignoredPatterns
        self.minimumSimilarity = minimumSimilarity
        self.algorithm = algorithm
        self.useIncremental = useIncremental
        self.cacheDirectory = cacheDirectory
        self.useParallelClones = useParallelClones
    }

    // MARK: Public

    /// Default configuration.
    public static let `default` = Self()

    /// High-performance configuration using suffix array.
    public static let highPerformance = Self(
        minimumTokens: 50,
        cloneTypes: [.exact, .near],
        algorithm: .suffixArray,
    )

    /// Configuration for Type-3 clones using MinHash + LSH.
    public static let type3Detection = Self(
        minimumTokens: 50,
        cloneTypes: [.semantic],
        minimumSimilarity: 0.5,
        algorithm: .minHashLSH,
    )

    /// Minimum tokens to consider as a clone.
    public var minimumTokens: Int

    /// Types of clones to detect.
    public var cloneTypes: Set<CloneType>

    /// Patterns to ignore (regex).
    public var ignoredPatterns: [String]

    /// Minimum similarity for near/semantic clones (0.0-1.0).
    public var minimumSimilarity: Double

    /// Detection algorithm to use.
    public var algorithm: DetectionAlgorithm

    /// Whether to use incremental detection (caches token sequences).
    public var useIncremental: Bool

    /// Cache directory for incremental detection.
    public var cacheDirectory: URL?

    /// Whether to use experimental parallel clone detection.
    public var useParallelClones: Bool

    /// Incremental configuration with caching enabled.
    public static func incremental(cacheDirectory: URL? = nil) -> Self {
        Self(
            minimumTokens: 50,
            cloneTypes: [.exact, .near],
            algorithm: .suffixArray,
            useIncremental: true,
            cacheDirectory: cacheDirectory,
        )
    }
}

// MARK: - DuplicationDetector

/// Detects code duplication in Swift source files.
public struct DuplicationDetector: Sendable {
    // MARK: Lifecycle

    public init(
        configuration: DuplicationConfiguration = .default,
        concurrency: ConcurrencyConfiguration = .default,
    ) {
        self.configuration = configuration
        self.concurrency = concurrency
        parser = SwiftFileParser()
        engine = DuplicationEngine(configuration: configuration, concurrency: concurrency)
    }

    // MARK: Public

    /// Configuration for detection.
    public let configuration: DuplicationConfiguration

    /// Concurrency configuration.
    public let concurrency: ConcurrencyConfiguration

    /// Detect clones in the given files.
    ///
    /// - Parameter files: Array of Swift file paths.
    /// - Returns: Array of clone groups found.
    public func detectClones(in files: [String]) async throws -> [CloneGroup] {
        // Scan for ignore directives
        let scanner = IgnoreDirectiveScanner()
        let ignoreRegions = try scanner.scan(files: files)

        var cloneGroups: [CloneGroup] = []

        // Extract token sequences once if needed for exact or near detection
        if configuration.cloneTypes.contains(.exact) || configuration.cloneTypes.contains(.near) {
            let sequences = try await extractTokenSequences(from: files)
            let engineClones = engine.detectClones(in: sequences)
            cloneGroups.append(contentsOf: engineClones)
        }

        if configuration.cloneTypes.contains(.semantic) {
            let semanticClones = try await detectSemanticClones(in: files)
            cloneGroups.append(contentsOf: semanticClones)
        }

        // Filter out clones in ignored regions
        let filteredGroups = cloneGroups.filteringIgnored(ignoreRegions)

        // Add code snippets to all clones
        return try await engine.addCodeSnippets(to: filteredGroups)
    }

    // MARK: Private

    /// The file parser.
    private let parser: SwiftFileParser

    /// The shared duplication engine.
    private let engine: DuplicationEngine

    // MARK: - Semantic Clone Detection

    private func detectSemanticClones(in files: [String]) async throws -> [CloneGroup] {
        switch configuration.algorithm {
        case .minHashLSH:
            // Use MinHash + LSH for Type-3 clone detection
            let parallelConfig: ParallelCloneConfiguration =
                configuration.useParallelClones
                ? .default
                : .sequential
            let detector = MinHashCloneDetector(
                minimumTokens: configuration.minimumTokens,
                shingleSize: 5,
                numHashes: 128,
                minimumSimilarity: configuration.minimumSimilarity,
                parallelConfig: parallelConfig
            )
            return try await detector.detect(in: files)

        case .rollingHash,
            .suffixArray:
            // Use AST fingerprinting for semantic clone detection
            let detector = SemanticCloneDetector(
                minimumNodes: configuration.minimumTokens / 5,  // Roughly 5 tokens per node
                minimumSimilarity: configuration.minimumSimilarity
            )
            return try await detector.detect(in: files)
        }
    }

    // MARK: - Helpers

    /// Extract token sequences from files in parallel.
    private func extractTokenSequences(from files: [String]) async throws -> [TokenSequence] {
        let extractor = TokenSequenceExtractor()

        // Use parallel processing with concurrency limits
        return try await ParallelProcessor.map(
            files,
            maxConcurrency: concurrency.maxConcurrentFiles,
        ) { [parser] file -> TokenSequence in
            let tree = try await parser.parse(file)
            let source = try String(contentsOfFile: file, encoding: .utf8)
            return extractor.extract(from: tree, file: file, source: source)
        }
    }
}

// MARK: - DuplicationReport

/// Report summarizing duplication findings.
public struct DuplicationReport: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        filesAnalyzed: Int,
        totalLines: Int,
        cloneGroups: [CloneGroup],
    ) {
        self.filesAnalyzed = filesAnalyzed
        self.totalLines = totalLines
        self.cloneGroups = cloneGroups
    }

    // MARK: Public

    /// Total files analyzed.
    public let filesAnalyzed: Int

    /// Total lines of code.
    public let totalLines: Int

    /// Clone groups found.
    public let cloneGroups: [CloneGroup]

    /// Total duplicated lines.
    public var duplicatedLines: Int {
        cloneGroups.reduce(0) { $0 + $1.duplicatedLines }
    }

    /// Duplication percentage.
    public var duplicationPercentage: Double {
        guard totalLines > 0 else { return 0 }
        return Double(duplicatedLines) / Double(totalLines) * 100
    }
}

// MARK: - Clone Group Utilities

// swa:ignore-unused - Public API for library consumers
extension [CloneGroup] {
    /// Remove duplicate clone groups based on their location fingerprints.
    ///
    /// Two clone groups are considered duplicates if they contain clones
    /// at the exact same file locations.
    public func deduplicated() -> [CloneGroup] {
        Array(self.uniqued(on: { group in
            group.clones
                .map { "\($0.file):\($0.startLine)-\($0.endLine)" }
                .sorted()
                .joined(separator: "|")
        }))
    }
}

// MARK: - GroupableWindow

/// Protocol for windows that can be grouped by the clone detection algorithm.
public protocol GroupableWindow {
    /// The file this window is from.
    var file: String { get }
    /// Start index in the file.
    var startIndex: Int { get }
    /// End index in the file.
    var endIndex: Int { get }
    /// Check if this window matches another for grouping purposes.
    func matches(_ other: Self) -> Bool
}

// MARK: - CloneDetectionUtilities

/// Shared utilities for clone detection algorithms.
public enum CloneDetectionUtilities {
    /// Check if two code windows overlap significantly.
    ///
    /// - Parameters:
    ///   - start1: Start index of first window.
    ///   - end1: End index of first window.
    ///   - start2: Start index of second window.
    ///   - end2: End index of second window.
    ///   - threshold: Minimum overlap to be considered significant.
    /// - Returns: True if the windows overlap more than the threshold.
    public static func hasSignificantOverlap(
        start1: Int,
        end1: Int,
        start2: Int,
        end2: Int,
        threshold: Int,
    ) -> Bool {
        let overlap = max(0, min(end1, end2) - max(start1, start2) + 1)
        return overlap > threshold
    }

    /// Calculate Jaccard similarity between two token sequences.
    ///
    /// - Parameters:
    ///   - tokens1: First token sequence.
    ///   - tokens2: Second token sequence.
    /// - Returns: Jaccard similarity coefficient (0.0 to 1.0).
    public static func jaccardSimilarity(_ tokens1: [String], _ tokens2: [String]) -> Double {
        let set1 = Set(tokens1)
        let set2 = Set(tokens2)

        let intersection = set1.intersection(set2).count
        let union = set1.union(set2).count

        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    /// Group matching windows, skipping overlapping windows in the same file.
    ///
    /// - Parameters:
    ///   - windows: Array of windows to group.
    ///   - overlapThreshold: Minimum overlap to skip (typically minimumTokens / 2).
    /// - Returns: Groups of matching windows (groups with < 2 windows are excluded).
    public static func groupMatchingWindows<W: GroupableWindow>(
        _ windows: [W],
        overlapThreshold: Int,
    ) -> [[W]] {
        var groups: [[W]] = []
        var used = Set<Int>()

        for (i, window1) in windows.enumerated() {
            guard !used.contains(i) else { continue }

            var group = [window1]
            used.insert(i)

            for (j, window2) in windows.enumerated() where j > i && !used.contains(j) {
                // Skip if same file and overlapping
                if window1.file == window2.file {
                    if hasSignificantOverlap(
                        start1: window1.startIndex,
                        end1: window1.endIndex,
                        start2: window2.startIndex,
                        end2: window2.endIndex,
                        threshold: overlapThreshold,
                    ) {
                        continue
                    }
                }

                // Verify windows match
                if window1.matches(window2) {
                    group.append(window2)
                    used.insert(j)
                }
            }

            if group.count >= 2 {
                groups.append(group)
            }
        }

        return groups
    }
}
