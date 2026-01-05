//  ParallelVerification.swift
//  SwiftStaticAnalysis
//  MIT License

import Algorithms
import AsyncAlgorithms
import Foundation
import SwiftStaticAnalysisCore

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
            for chunk in pairs.chunks(ofCount: chunkSize) {
                group.addTask {
                    self.verifySequential(Array(chunk), documentMap: documentMap)
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

        for chunk in pairs.chunks(ofCount: batchSize) {
            let batch = Set(chunk)

            let batchResults = await verifier.verifyCandidatePairs(
                batch,
                documentMap: documentMap
            )

            allResults.append(contentsOf: batchResults)
            processedCount += chunk.count

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

// MARK: - VerificationProgress

/// Progress update for streaming verification.
public struct VerificationProgress: Sendable {
    /// Number of pairs processed so far.
    public let processed: Int

    /// Total number of pairs to process.
    public let total: Int

    /// Verified pairs from this batch.
    public let batchResults: [ClonePairInfo]

    /// Progress percentage (0.0 - 1.0).
    public var progress: Double {
        total > 0 ? Double(processed) / Double(total) : 1.0
    }
}

// MARK: - StreamingVerifier

/// Streaming verification with AsyncChannel for progress and backpressure.
///
/// Uses swift-async-algorithms to stream results as they become available,
/// enabling memory-bounded processing for large candidate sets.
///
/// ## Usage
///
/// ```swift
/// let verifier = StreamingVerifier()
/// for await progress in verifier.verifyStreaming(candidates, documentMap: docs) {
///     print("Progress: \(progress.progress * 100)%")
///     allResults.append(contentsOf: progress.batchResults)
/// }
/// ```
///
/// ## Performance Characteristics
///
/// - Results streamed immediately after batch completion
/// - Backpressure via bounded buffer prevents memory blow-up
/// - Suitable for ParallelMode.maximum
public struct StreamingVerifier: Sendable {
    // MARK: Lifecycle

    /// Create a streaming verifier.
    ///
    /// - Parameters:
    ///   - minimumSimilarity: Minimum similarity threshold.
    ///   - batchSize: Number of pairs per streaming batch.
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - bufferSize: Size of the streaming buffer for backpressure.
    public init(
        minimumSimilarity: Double = 0.5,
        batchSize: Int = 500,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        bufferSize: Int = 4
    ) {
        self.verifier = ParallelVerifier(
            minimumSimilarity: minimumSimilarity,
            minParallelPairs: 1,
            maxConcurrency: maxConcurrency
        )
        self.batchSize = max(1, batchSize)
        self.bufferSize = max(1, bufferSize)
    }

    // MARK: Public

    /// Batch size for streaming.
    public let batchSize: Int

    /// Buffer size for backpressure.
    public let bufferSize: Int

    /// Stream verification progress and results.
    ///
    /// - Parameters:
    ///   - candidatePairs: Set of candidate document pairs.
    ///   - documentMap: Map from document ID to shingled document.
    /// - Returns: AsyncStream of verification progress updates.
    public func verifyStreaming(
        _ candidatePairs: Set<DocumentPair>,
        documentMap: [Int: ShingledDocument]
    ) -> AsyncStream<VerificationProgress> {
        let pairs = Array(candidatePairs)
        let total = pairs.count
        let batchSize = self.batchSize
        let verifier = self.verifier

        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            Task {
                var processedCount = 0

                for chunk in pairs.chunks(ofCount: batchSize) {
                    let batch = Set(chunk)

                    let batchResults = await verifier.verifyCandidatePairs(
                        batch,
                        documentMap: documentMap
                    )

                    processedCount += chunk.count

                    continuation.yield(
                        VerificationProgress(
                            processed: processedCount,
                            total: total,
                            batchResults: batchResults
                        )
                    )
                }

                continuation.finish()
            }
        }
    }

    /// Stream only verified results (no progress metadata).
    ///
    /// - Parameters:
    ///   - candidatePairs: Set of candidate document pairs.
    ///   - documentMap: Map from document ID to shingled document.
    /// - Returns: AsyncStream of verified clone pairs.
    public func streamResults(
        _ candidatePairs: Set<DocumentPair>,
        documentMap: [Int: ShingledDocument]
    ) -> AsyncStream<ClonePairInfo> {
        let pairs = Array(candidatePairs)
        let batchSize = self.batchSize
        let verifier = self.verifier

        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize * batchSize)) { continuation in
            Task {
                for chunk in pairs.chunks(ofCount: batchSize) {
                    let batch = Set(chunk)

                    let batchResults = await verifier.verifyCandidatePairs(
                        batch,
                        documentMap: documentMap
                    )

                    for result in batchResults {
                        continuation.yield(result)
                    }
                }

                continuation.finish()
            }
        }
    }

    /// Collect all results from streaming (convenience method).
    ///
    /// - Parameters:
    ///   - candidatePairs: Set of candidate document pairs.
    ///   - documentMap: Map from document ID to shingled document.
    /// - Returns: Array of verified clone pairs.
    public func collectResults(
        _ candidatePairs: Set<DocumentPair>,
        documentMap: [Int: ShingledDocument]
    ) async -> [ClonePairInfo] {
        var results: [ClonePairInfo] = []

        for await progress in verifyStreaming(candidatePairs, documentMap: documentMap) {
            results.append(contentsOf: progress.batchResults)
        }

        return results
    }

    // MARK: Private

    /// Internal parallel verifier.
    private let verifier: ParallelVerifier
}

// MARK: - ParallelMode Integration

extension ParallelVerifier {
    /// Create a verifier configured for the specified parallel mode.
    ///
    /// - Parameter mode: The parallel execution mode.
    /// - Returns: Configured ParallelVerifier.
    public static func forMode(_ mode: ParallelMode) -> ParallelVerifier {
        switch mode {
        case .none:
            ParallelVerifier(
                minParallelPairs: Int.max,  // Force sequential
                maxConcurrency: 1
            )

        case .safe:
            ParallelVerifier()  // Default configuration

        case .maximum:
            ParallelVerifier(
                minParallelPairs: 10,  // Aggressive parallelism
                maxConcurrency: ProcessInfo.processInfo.activeProcessorCount * 2
            )
        }
    }
}

extension StreamingVerifier {
    /// Create a streaming verifier configured for maximum mode.
    ///
    /// - Parameter maxConcurrency: Optional concurrency override.
    /// - Returns: Configured StreamingVerifier.
    public static func forMaximumMode(
        maxConcurrency: Int? = nil
    ) -> StreamingVerifier {
        StreamingVerifier(
            batchSize: 500,
            maxConcurrency: maxConcurrency ?? ProcessInfo.processInfo.activeProcessorCount * 2,
            bufferSize: 8
        )
    }
}
