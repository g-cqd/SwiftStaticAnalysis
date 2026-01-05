//  IncrementalDuplicationDetector.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore

// MARK: - IncrementalDuplicationResult

/// Result of incremental duplication detection.
public struct IncrementalDuplicationResult: Sendable {
    /// Detected clone groups.
    public let cloneGroups: [CloneGroup]

    /// Files that were analyzed (not cached).
    public let analyzedFiles: [String]

    /// Files loaded from cache.
    public let cachedFiles: [String]

    /// Cache hit rate percentage.
    public var cacheHitRate: Double {
        let total = analyzedFiles.count + cachedFiles.count
        return total > 0 ? Double(cachedFiles.count) / Double(total) * 100 : 0
    }
}

// MARK: - IncrementalDuplicationDetector

/// Actor-based incremental duplication detector with caching.
public actor IncrementalDuplicationDetector {
    // MARK: Lifecycle

    // MARK: - Initialization

    public init(
        configuration: DuplicationConfiguration = .incremental(),
        concurrency: ConcurrencyConfiguration = .default,
    ) {
        self.configuration = configuration
        self.concurrency = concurrency
        tokenCache = TokenSequenceCache(cacheDirectory: configuration.cacheDirectory)
        changeDetector = ChangeDetector()
        parser = SwiftFileParser()
        engine = DuplicationEngine(configuration: configuration, concurrency: concurrency)
    }

    // MARK: Public

    /// Configuration for detection.
    public let configuration: DuplicationConfiguration

    /// Concurrency configuration.
    public let concurrency: ConcurrencyConfiguration

    /// Initialize by loading cache from disk.
    public func initialize() async throws {
        guard !isInitialized else { return }
        try await tokenCache.load()
        isInitialized = true
    }

    /// Save cache to disk.
    public func saveCache() async throws {
        try await tokenCache.save()
    }

    /// Clear the token cache.
    public func clearCache() async {
        await tokenCache.clear()
    }

    // MARK: - Detection

    /// Detect clones incrementally, using cached token sequences where available.
    ///
    /// - Parameter files: Files to analyze.
    /// - Returns: Incremental duplication result.
    public func detectClones(in files: [String]) async throws -> IncrementalDuplicationResult {
        try await initialize()

        // Compute file hashes
        let fileHashes = await computeFileHashes(for: files)

        // Determine which files need re-tokenization
        var filesToAnalyze: [String] = []
        var cachedFiles: [String] = []

        for file in files {
            if let hash = fileHashes[file], await tokenCache.hasValid(file: file, hash: hash) {
                cachedFiles.append(file)
            } else {
                filesToAnalyze.append(file)
            }
        }

        // Extract token sequences
        var sequences: [TokenSequence] = []

        // Load cached sequences
        for file in cachedFiles {
            if let hash = fileHashes[file],
                let cached = await tokenCache.get(file: file, currentHash: hash)
            {
                sequences.append(cached.toTokenSequence())
            }
        }

        // Extract new sequences
        if !filesToAnalyze.isEmpty {
            let extractor = TokenSequenceExtractor()

            let newSequences = try await ParallelProcessor.map(
                filesToAnalyze,
                maxConcurrency: concurrency.maxConcurrentFiles,
            ) { [parser] file -> TokenSequence in
                let tree = try await parser.parse(file)
                let source = try String(contentsOfFile: file, encoding: .utf8)
                return extractor.extract(from: tree, file: file, source: source)
            }

            // Cache new sequences
            for (index, sequence) in newSequences.enumerated() {
                let file = filesToAnalyze[index]
                if let hash = fileHashes[file] {
                    await tokenCache.set(sequence.toCached(contentHash: hash))
                }
            }

            sequences.append(contentsOf: newSequences)
        }

        // Run detection
        let cloneGroups = engine.detectClones(in: sequences)

        // Add code snippets
        let groupsWithSnippets = try await engine.addCodeSnippets(to: cloneGroups)

        return IncrementalDuplicationResult(
            cloneGroups: groupsWithSnippets,
            analyzedFiles: filesToAnalyze,
            cachedFiles: cachedFiles,
        )
    }

    // MARK: - Statistics

    /// Get cache statistics.
    public func cacheStatistics() async -> TokenSequenceCache.Statistics {
        await tokenCache.statistics()
    }

    // MARK: Private

    /// Token sequence cache.
    private let tokenCache: TokenSequenceCache

    /// Change detector for file change detection.
    private let changeDetector: ChangeDetector

    /// File parser.
    private let parser: SwiftFileParser

    /// The shared duplication engine.
    private let engine: DuplicationEngine

    /// Whether the cache has been initialized.
    private var isInitialized: Bool = false

    // MARK: - Private Helpers

    /// Compute content hashes for files.
    private func computeFileHashes(for files: [String]) async -> [String: UInt64] {
        var hashes: [String: UInt64] = [:]

        for file in files {
            if let data = FileManager.default.contents(atPath: file) {
                hashes[file] = FNV1a.hash(data)
            }
        }

        return hashes
    }
}
