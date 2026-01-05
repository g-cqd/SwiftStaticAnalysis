//
//  ParallelVerification.swift
//  SwiftStaticAnalysis
//
//  Parallel verification of LSH candidate pairs.
//  Computes exact Jaccard similarity for candidates concurrently.
//

import Foundation

// MARK: - ParallelVerifier

/// Parallel verification of LSH candidate pairs.
///
/// Verifies candidate pairs by computing exact Jaccard similarity
/// concurrently. Each pair is processed independently.
///
/// ## Performance Characteristics
///
/// - Small batches (< minParallelPairs): Sequential fallback
/// - Large batches: Near-linear speedup up to maxConcurrency
///
/// ## Thread Safety
///
/// - Fully thread-safe using Swift Concurrency
/// - Each pair is verified independently
/// - Document map is read-only during verification
public struct ParallelVerifier: Sendable {
    // MARK: Lifecycle

    /// Create a parallel verifier.
    ///
    /// - Parameters:
    ///   - minimumSimilarity: Minimum similarity threshold.
    ///   - minParallelPairs: Minimum pairs to trigger parallelism.
    ///   - maxConcurrency: Maximum concurrent tasks.
    public init(
        minimumSimilarity: Double = 0.5,
        minParallelPairs: Int = 100,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.minimumSimilarity = max(0, min(1, minimumSimilarity))
        self.minParallelPairs = max(1, minParallelPairs)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    // MARK: Public

    /// Minimum similarity threshold.
    public let minimumSimilarity: Double

    /// Minimum pairs to trigger parallel processing.
    public let minParallelPairs: Int

    /// Maximum concurrent tasks.
    public let maxConcurrency: Int

    /// Verify candidate pairs in parallel.
    ///
    /// - Parameters:
    ///   - candidatePairs: Set of candidate document pairs.
    ///   - documentMap: Map from document ID to shingled document.
    /// - Returns: Array of verified clone pairs above threshold.
    public func verifyCandidatePairs(
        _ candidatePairs: Set<DocumentPair>,
        documentMap: [Int: ShingledDocument]
    ) async -> [ClonePairInfo] {
        let pairs = Array(candidatePairs)

        // Fall back to sequential for small batches
        guard pairs.count >= minParallelPairs else {
            return verifySequential(pairs, documentMap: documentMap)
        }

        // Parallel verification with chunking
        let chunkSize = max(1, pairs.count / maxConcurrency)

        return await withTaskGroup(of: [ClonePairInfo].self) { group in
            for chunkStart in stride(from: 0, to: pairs.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, pairs.count)
                let chunk = Array(pairs[chunkStart..<chunkEnd])

                group.addTask {
                    self.verifySequential(chunk, documentMap: documentMap)
                }
            }

            var allPairs: [ClonePairInfo] = []
            for await partial in group {
                allPairs.append(contentsOf: partial)
            }
            return allPairs
        }
    }

    /// Verify a single pair of documents.
    ///
    /// - Parameters:
    ///   - pair: The document pair to verify.
    ///   - documentMap: Map from document ID to shingled document.
    /// - Returns: Clone pair info if similarity is above threshold, nil otherwise.
    public func verifyPair(
        _ pair: DocumentPair,
        documentMap: [Int: ShingledDocument]
    ) -> ClonePairInfo? {
        guard let doc1 = documentMap[pair.id1],
            let doc2 = documentMap[pair.id2]
        else { return nil }

        // Skip overlapping in same file
        if doc1.file == doc2.file {
            let overlaps = !(doc1.endLine < doc2.startLine || doc2.endLine < doc1.startLine)
            if overlaps { return nil }
        }

        let similarity = MinHashGenerator.exactJaccardSimilarity(doc1, doc2)

        guard similarity >= minimumSimilarity else { return nil }

        return ClonePairInfo(doc1: doc1, doc2: doc2, similarity: similarity)
    }

    // MARK: Private

    /// Sequential verification for small batches or as chunk processor.
    private func verifySequential(
        _ pairs: [DocumentPair],
        documentMap: [Int: ShingledDocument]
    ) -> [ClonePairInfo] {
        var results: [ClonePairInfo] = []

        for pair in pairs {
            if let verified = verifyPair(pair, documentMap: documentMap) {
                results.append(verified)
            }
        }

        return results
    }
}

// MARK: - BatchVerifier

/// Batch verification with progress tracking.
///
/// Useful for large verification jobs where progress feedback is needed.
public struct BatchVerifier: Sendable {
    // MARK: Lifecycle

    /// Create a batch verifier.
    ///
    /// - Parameters:
    ///   - minimumSimilarity: Minimum similarity threshold.
    ///   - batchSize: Number of pairs per batch.
    ///   - maxConcurrency: Maximum concurrent tasks.
    public init(
        minimumSimilarity: Double = 0.5,
        batchSize: Int = 1000,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.verifier = ParallelVerifier(
            minimumSimilarity: minimumSimilarity,
            minParallelPairs: 1,  // Always use parallel within batches
            maxConcurrency: maxConcurrency
        )
        self.batchSize = max(1, batchSize)
    }

    // MARK: Public

    /// Batch size for processing.
    public let batchSize: Int

    /// Verify candidate pairs in batches.
    ///
    /// - Parameters:
    ///   - candidatePairs: Set of candidate document pairs.
    ///   - documentMap: Map from document ID to shingled document.
    ///   - progressHandler: Optional handler called after each batch.
    /// - Returns: Array of verified clone pairs above threshold.
    public func verifyCandidatePairs(
        _ candidatePairs: Set<DocumentPair>,
        documentMap: [Int: ShingledDocument],
        progressHandler: ((Int, Int) async -> Void)? = nil
    ) async -> [ClonePairInfo] {
        let pairs = Array(candidatePairs)
        var allResults: [ClonePairInfo] = []
        var processedCount = 0

        for batchStart in stride(from: 0, to: pairs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, pairs.count)
            let batch = Set(pairs[batchStart..<batchEnd])

            let batchResults = await verifier.verifyCandidatePairs(
                batch,
                documentMap: documentMap
            )

            allResults.append(contentsOf: batchResults)
            processedCount = batchEnd

            if let handler = progressHandler {
                await handler(processedCount, pairs.count)
            }
        }

        return allResults
    }

    // MARK: Private

    /// Internal parallel verifier.
    private let verifier: ParallelVerifier
}
