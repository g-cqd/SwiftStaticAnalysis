//
//  ParallelMinHash.swift
//  SwiftStaticAnalysis
//
//  Parallel MinHash signature computation using Swift Concurrency.
//  Computes signatures for multiple documents concurrently.
//

import Foundation

// MARK: - ParallelMinHashGenerator

/// Parallel MinHash signature computation using task groups.
///
/// This generator wraps the standard `MinHashGenerator` and distributes
/// signature computation across multiple concurrent tasks for improved
/// throughput on large document sets.
///
/// ## Performance Characteristics
///
/// - Small batches (< minParallelDocuments): Sequential fallback
/// - Large batches: Near-linear speedup up to maxConcurrency
///
/// ## Thread Safety
///
/// - Fully thread-safe using Swift Concurrency
/// - Each document is processed independently
/// - Results are collected with order preservation
public struct ParallelMinHashGenerator: Sendable {
    // MARK: Lifecycle

    /// Create a parallel MinHash generator.
    ///
    /// - Parameters:
    ///   - numHashes: Number of hash functions (signature dimension).
    ///   - seed: Random seed for reproducibility.
    ///   - minParallelDocuments: Minimum documents to trigger parallelism.
    ///   - maxConcurrency: Maximum concurrent tasks.
    public init(
        numHashes: Int = 128,
        seed: UInt64 = 42,
        minParallelDocuments: Int = 50,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.baseGenerator = MinHashGenerator(numHashes: numHashes, seed: seed)
        self.minParallelDocuments = max(1, minParallelDocuments)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    // MARK: Public

    /// Number of hash functions.
    public var numHashes: Int { baseGenerator.numHashes }

    /// Compute signatures in parallel for multiple documents.
    ///
    /// - Parameter documents: Documents to compute signatures for.
    /// - Returns: Array of signatures in the same order as input documents.
    public func computeSignatures(
        for documents: [ShingledDocument]
    ) async -> [MinHashSignature] {
        // Fall back to sequential for small batches
        guard documents.count >= minParallelDocuments else {
            return documents.map { baseGenerator.computeSignature(for: $0) }
        }

        // Parallel computation with order preservation
        return await withTaskGroup(of: (Int, MinHashSignature).self) { group in
            for (index, document) in documents.enumerated() {
                group.addTask {
                    (index, self.baseGenerator.computeSignature(for: document))
                }
            }

            // Collect results preserving order
            var signatures = [MinHashSignature?](repeating: nil, count: documents.count)
            for await (index, signature) in group {
                signatures[index] = signature
            }

            return signatures.compactMap { $0 }
        }
    }

    /// Compute signatures using chunked parallelism.
    ///
    /// This variant limits concurrency by processing documents in chunks,
    /// reducing memory overhead for very large document sets.
    ///
    /// - Parameters:
    ///   - documents: Documents to compute signatures for.
    ///   - chunkSize: Number of documents per chunk (default: maxConcurrency * 2).
    /// - Returns: Array of signatures in the same order as input documents.
    public func computeSignaturesChunked(
        for documents: [ShingledDocument],
        chunkSize: Int? = nil
    ) async -> [MinHashSignature] {
        guard documents.count >= minParallelDocuments else {
            return documents.map { baseGenerator.computeSignature(for: $0) }
        }

        let effectiveChunkSize = chunkSize ?? maxConcurrency * 2
        var allSignatures: [MinHashSignature] = []
        allSignatures.reserveCapacity(documents.count)

        for chunkStart in stride(from: 0, to: documents.count, by: effectiveChunkSize) {
            let chunkEnd = min(chunkStart + effectiveChunkSize, documents.count)
            let chunk = Array(documents[chunkStart..<chunkEnd])

            let chunkSignatures = await withTaskGroup(of: (Int, MinHashSignature).self) { group in
                for (localIndex, document) in chunk.enumerated() {
                    group.addTask {
                        (localIndex, self.baseGenerator.computeSignature(for: document))
                    }
                }

                var results = [MinHashSignature?](repeating: nil, count: chunk.count)
                for await (index, signature) in group {
                    results[index] = signature
                }

                return results.compactMap { $0 }
            }

            allSignatures.append(contentsOf: chunkSignatures)
        }

        return allSignatures
    }

    // MARK: Private

    /// Base sequential generator.
    private let baseGenerator: MinHashGenerator

    /// Minimum documents to use parallel processing.
    private let minParallelDocuments: Int

    /// Maximum concurrent tasks.
    private let maxConcurrency: Int
}

// MARK: - ParallelShingleGenerator

/// Parallel shingle generation for multiple token sequences.
///
/// Generates shingled documents for multiple files concurrently,
/// with deterministic ID assignment using pre-computed offsets.
public struct ParallelShingleGenerator: Sendable {
    // MARK: Lifecycle

    /// Create a parallel shingle generator.
    ///
    /// - Parameters:
    ///   - shingleSize: Size of each shingle (number of tokens).
    ///   - normalize: Whether to normalize identifiers/literals.
    ///   - minParallelSequences: Minimum sequences to trigger parallelism.
    ///   - maxConcurrency: Maximum concurrent tasks.
    public init(
        shingleSize: Int = 5,
        normalize: Bool = true,
        minParallelSequences: Int = 10,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.baseGenerator = ShingleGenerator(shingleSize: shingleSize, normalize: normalize)
        self.minParallelSequences = max(1, minParallelSequences)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    // MARK: Public

    /// Shingle size.
    public var shingleSize: Int { baseGenerator.shingleSize }

    /// Generate shingled documents for multiple sequences in parallel.
    ///
    /// Document IDs are assigned deterministically by pre-computing
    /// the number of documents each sequence will produce.
    ///
    /// - Parameters:
    ///   - sequences: Token sequences to process.
    ///   - blockSize: Minimum tokens per block.
    /// - Returns: Array of shingled documents with contiguous IDs.
    public func generateBlockDocuments(
        from sequences: [TokenSequence],
        blockSize: Int
    ) async -> [ShingledDocument] {
        guard !sequences.isEmpty else { return [] }

        // For small batches, use sequential
        if sequences.count < minParallelSequences {
            return generateSequential(from: sequences, blockSize: blockSize)
        }

        // Pre-compute document counts per sequence for deterministic ID assignment
        let documentCounts = sequences.map { sequence -> Int in
            guard sequence.tokens.count >= blockSize else { return 0 }
            let stride = max(1, blockSize / 2)
            return (sequence.tokens.count - blockSize) / stride + 1
        }

        // Compute starting IDs for each sequence
        var startIds: [Int] = []
        startIds.reserveCapacity(sequences.count)
        var currentId = 0
        for count in documentCounts {
            startIds.append(currentId)
            currentId += count
        }

        // Parallel generation with pre-computed IDs
        return await withTaskGroup(of: (Int, [ShingledDocument]).self) { group in
            for (index, sequence) in sequences.enumerated() {
                let startId = startIds[index]
                group.addTask {
                    let docs = self.baseGenerator.generateBlockDocuments(
                        from: sequence,
                        blockSize: blockSize,
                        startId: startId
                    )
                    return (index, docs)
                }
            }

            // Collect and flatten results in order
            var allDocsByIndex: [(Int, [ShingledDocument])] = []
            allDocsByIndex.reserveCapacity(sequences.count)
            for await result in group {
                allDocsByIndex.append(result)
            }

            // Sort by original index and flatten
            allDocsByIndex.sort { $0.0 < $1.0 }
            return allDocsByIndex.flatMap(\.1)
        }
    }

    // MARK: Private

    /// Base sequential generator.
    private let baseGenerator: ShingleGenerator

    /// Minimum sequences to use parallel processing.
    private let minParallelSequences: Int

    /// Maximum concurrent tasks.
    private let maxConcurrency: Int

    /// Sequential fallback for small batches.
    private func generateSequential(
        from sequences: [TokenSequence],
        blockSize: Int
    ) -> [ShingledDocument] {
        var allDocuments: [ShingledDocument] = []
        var currentId = 0

        for sequence in sequences {
            let documents = baseGenerator.generateBlockDocuments(
                from: sequence,
                blockSize: blockSize,
                startId: currentId
            )
            allDocuments.append(contentsOf: documents)
            currentId += documents.count
        }

        return allDocuments
    }
}
