//
//  ParallelLSH.swift
//  SwiftStaticAnalysis
//
//  Parallel LSH configuration and utilities.
//  Core parallel methods are in LSH.swift (findCandidatePairsParallel).
//

import Foundation

// MARK: - ParallelLSHConfiguration

/// Configuration for parallel LSH operations.
public struct ParallelLSHConfiguration: Sendable {
    // MARK: Lifecycle

    /// Create parallel LSH configuration.
    ///
    /// - Parameters:
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - minParallelBands: Minimum bands to trigger parallel processing.
    public init(
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        minParallelBands: Int = 4
    ) {
        self.maxConcurrency = max(1, maxConcurrency)
        self.minParallelBands = max(1, minParallelBands)
    }

    // MARK: Public

    /// Default configuration.
    public static let `default` = ParallelLSHConfiguration()

    /// Maximum concurrent tasks.
    public let maxConcurrency: Int

    /// Minimum bands to trigger parallel processing.
    public let minParallelBands: Int
}

// MARK: - ParallelLSHPipeline

/// Complete parallel LSH pipeline for finding similar documents.
public struct ParallelLSHPipeline: Sendable {
    // MARK: Lifecycle

    /// Create a parallel LSH pipeline.
    ///
    /// - Parameters:
    ///   - numHashes: Number of hash functions.
    ///   - threshold: Similarity threshold.
    ///   - seed: Random seed.
    ///   - maxConcurrency: Maximum concurrent tasks.
    public init(
        numHashes: Int = 128,
        threshold: Double = 0.5,
        seed: UInt64 = 42,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.minHashGenerator = ParallelMinHashGenerator(
            numHashes: numHashes,
            seed: seed,
            maxConcurrency: maxConcurrency
        )
        let (b, r) = LSHIndex.optimalBandsAndRows(
            signatureSize: numHashes,
            threshold: threshold
        )
        self.bands = b
        self.rows = r
        self.threshold = threshold
        self.maxConcurrency = maxConcurrency
    }

    // MARK: Public

    /// Parallel MinHash generator.
    public let minHashGenerator: ParallelMinHashGenerator

    /// LSH index parameters.
    public let bands: Int
    public let rows: Int

    /// Similarity threshold.
    public let threshold: Double

    /// Maximum concurrent tasks.
    public let maxConcurrency: Int

    /// Find similar pairs among documents using parallel processing.
    ///
    /// - Parameters:
    ///   - documents: Array of shingled documents.
    ///   - verifyWithExact: Whether to verify candidates with exact Jaccard.
    /// - Returns: Array of similar pairs above threshold.
    public func findSimilarPairs(
        _ documents: [ShingledDocument],
        verifyWithExact: Bool = false
    ) async -> [SimilarPair] {
        // Parallel signature computation
        let signatures = await minHashGenerator.computeSignatures(for: documents)

        // Build index (sequential - write-bound)
        var index = LSHIndex(bands: bands, rows: rows)
        index.insert(signatures)

        // Parallel candidate finding
        let candidatePairs = await index.findCandidatePairsParallel(
            maxConcurrency: maxConcurrency
        )

        // Build document lookup
        let documentMap = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        // Verify and filter (can be parallelized separately)
        var results: [SimilarPair] = []
        for pair in candidatePairs {
            guard let sig1 = index.signature(for: pair.id1),
                  let sig2 = index.signature(for: pair.id2)
            else { continue }

            let similarity: Double =
                if verifyWithExact,
                   let doc1 = documentMap[pair.id1],
                   let doc2 = documentMap[pair.id2]
                {
                    MinHashGenerator.exactJaccardSimilarity(doc1, doc2)
                } else {
                    sig1.estimateSimilarity(with: sig2)
                }

            if similarity >= threshold {
                results.append(
                    SimilarPair(
                        documentId1: pair.id1,
                        documentId2: pair.id2,
                        similarity: similarity
                    )
                )
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }
}
