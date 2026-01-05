//
//  LSH.swift
//  SwiftStaticAnalysis
//
//  Locality Sensitive Hashing (LSH) for efficient similarity search.
//
//  LSH uses the banding technique to bucket MinHash signatures so that
//  similar documents hash to the same bucket with high probability.
//  This reduces similarity search from O(n^2) to approximately O(n).
//
//  The probability that two documents with Jaccard similarity s become
//  candidates is: 1 - (1 - s^r)^b
//  where b = number of bands, r = rows per band.
//

import Algorithms
import AsyncAlgorithms
import Foundation
import SwiftStaticAnalysisCore

// MARK: - LSHQueryable

/// Protocol for LSH indices that can query for similar documents.
public protocol LSHQueryable: Sendable {
    /// Query for candidate documents similar to the given signature.
    func query(_ signature: MinHashSignature) -> Set<Int>

    /// Get the signature for a document ID.
    func signature(for documentId: Int) -> MinHashSignature?
}

extension LSHQueryable {
    /// Query and rank results by similarity.
    ///
    /// - Parameters:
    ///   - signature: The query signature.
    ///   - threshold: Minimum similarity to include.
    /// - Returns: Array of (documentId, similarity) pairs, sorted by similarity.
    public func queryWithSimilarity(
        _ signature: MinHashSignature,
        threshold: Double = 0.0,
    ) -> [(documentId: Int, similarity: Double)] {
        let candidates = query(signature)

        var results: [(documentId: Int, similarity: Double)] = []
        for docId in candidates {
            guard let candidateSignature = self.signature(for: docId) else { continue }
            let similarity = signature.estimateSimilarity(with: candidateSignature)
            if similarity >= threshold {
                results.append((docId, similarity))
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }
}

// MARK: - LSHIndex

/// Locality Sensitive Hashing index for efficient similarity search.
public struct LSHIndex: Sendable, LSHQueryable {
    // MARK: Lifecycle

    /// Create an LSH index with given parameters.
    ///
    /// The choice of bands (b) and rows (r) determines the similarity threshold.
    /// For a signature of size n = b * r:
    /// - Higher b, lower r: More sensitive (catches lower similarities)
    /// - Lower b, higher r: More specific (fewer false positives)
    ///
    /// - Parameters:
    ///   - bands: Number of bands to use.
    ///   - rows: Rows per band.
    public init(bands: Int, rows: Int) {
        self.bands = bands
        self.rows = rows
        buckets = Array(repeating: [:], count: bands)
        signatures = [:]
    }

    /// Create an LSH index optimized for a target similarity threshold.
    ///
    /// - Parameters:
    ///   - signatureSize: Size of MinHash signatures.
    ///   - threshold: Target Jaccard similarity threshold (0.0 to 1.0).
    public init(signatureSize: Int, threshold: Double) {
        let (b, r) = Self.optimalBandsAndRows(signatureSize: signatureSize, threshold: threshold)
        bands = b
        rows = r
        buckets = Array(repeating: [:], count: b)
        signatures = [:]
    }

    // MARK: Public

    /// Number of bands.
    public let bands: Int

    /// Rows per band.
    public let rows: Int

    /// Compute optimal bands and rows for a given threshold.
    ///
    /// The threshold where probability of becoming candidate is 0.5 is:
    /// t = (1/b)^(1/r)
    ///
    /// - Parameters:
    ///   - signatureSize: Size of MinHash signatures.
    ///   - threshold: Target Jaccard similarity threshold.
    /// - Returns: Tuple of (bands, rows).
    public static func optimalBandsAndRows(
        signatureSize: Int,
        threshold: Double,
    ) -> (bands: Int, rows: Int) {
        var bestBands = 1
        var bestRows = signatureSize
        var bestError = Double.infinity

        // Search for b, r such that n = b * r and threshold = (1/b)^(1/r)
        for b in 1...signatureSize {
            let r = signatureSize / b
            guard r > 0, b * r <= signatureSize else { continue }

            // Threshold where P(candidate) = 0.5
            let t = pow(1.0 / Double(b), 1.0 / Double(r))
            let error = abs(t - threshold)

            if error < bestError {
                bestError = error
                bestBands = b
                bestRows = r
            }
        }

        return (bestBands, bestRows)
    }

    /// Index a signature.
    ///
    /// - Parameter signature: The MinHash signature to index.
    public mutating func insert(_ signature: MinHashSignature) {
        guard signature.values.count >= bands * rows else { return }

        signatures[signature.documentId] = signature

        // Hash each band
        for band in 0..<bands {
            let bandHash = hashBand(signature: signature, band: band)
            buckets[band][bandHash, default: []].append(signature.documentId)
        }
    }

    /// Index multiple signatures.
    public mutating func insert(_ signatures: [MinHashSignature]) {
        for signature in signatures {
            insert(signature)
        }
    }

    /// Find candidate pairs (documents that hash to the same bucket in at least one band).
    ///
    /// - Returns: Set of candidate document ID pairs.
    public func findCandidatePairs() -> Set<DocumentPair> {
        var candidates = Set<DocumentPair>()

        for band in 0..<bands {
            for (_, docIds) in buckets[band] {
                // All pairs in the same bucket are candidates
                for pair in docIds.combinations(ofCount: 2) {
                    candidates.insert(DocumentPair(id1: pair[0], id2: pair[1]))
                }
            }
        }

        return candidates
    }

    /// Find similar documents to a query.
    ///
    /// - Parameter signature: The query signature.
    /// - Returns: Set of candidate document IDs.
    public func query(_ signature: MinHashSignature) -> Set<Int> {
        guard signature.values.count >= bands * rows else { return [] }

        var candidates = Set<Int>()

        for band in 0..<bands {
            let bandHash = hashBand(signature: signature, band: band)
            if let docIds = buckets[band][bandHash] {
                candidates.formUnion(docIds)
            }
        }

        // Remove self if present
        candidates.remove(signature.documentId)

        return candidates
    }

    /// Get the signature for a document ID.
    public func signature(for documentId: Int) -> MinHashSignature? {
        signatures[documentId]
    }

    /// Find candidate pairs in a specific range of bands.
    ///
    /// This method enables parallel candidate finding by processing
    /// different band ranges concurrently.
    ///
    /// - Parameters:
    ///   - startBand: Starting band index (inclusive).
    ///   - endBand: Ending band index (exclusive).
    /// - Returns: Candidate pairs found in the specified bands.
    public func findCandidatePairsInBands(from startBand: Int, to endBand: Int) -> Set<DocumentPair> {
        var candidates = Set<DocumentPair>()

        for band in startBand..<min(endBand, bands) {
            for (_, docIds) in buckets[band] {
                for pair in docIds.combinations(ofCount: 2) {
                    candidates.insert(DocumentPair(id1: pair[0], id2: pair[1]))
                }
            }
        }

        return candidates
    }

    /// Find candidate pairs using parallel band processing.
    ///
    /// Each band range is processed concurrently, then results are merged.
    ///
    /// - Parameter maxConcurrency: Maximum concurrent tasks.
    /// - Returns: Set of candidate document pairs.
    public func findCandidatePairsParallel(
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async -> Set<DocumentPair> {
        // Use sequential for small band counts
        if bands < 4 {
            return findCandidatePairs()
        }

        let bandsPerChunk = max(1, bands / maxConcurrency)

        return await withTaskGroup(of: Set<DocumentPair>.self) { group in
            for chunk in (0..<bands).chunks(ofCount: bandsPerChunk) {
                let startBand = chunk.lowerBound
                let endBand = chunk.upperBound

                group.addTask {
                    self.findCandidatePairsInBands(from: startBand, to: endBand)
                }
            }

            var allCandidates = Set<DocumentPair>()
            for await partialCandidates in group {
                allCandidates.formUnion(partialCandidates)
            }
            return allCandidates
        }
    }

    /// Stream candidate pairs as they're discovered (band by band).
    ///
    /// This method yields candidate pairs incrementally, enabling:
    /// - Early results for progressive UI updates
    /// - Memory-bounded processing via backpressure
    /// - Suitable for ParallelMode.maximum
    ///
    /// - Parameter bufferSize: Size of the streaming buffer.
    /// - Returns: AsyncStream of candidate document pairs.
    public func findCandidatePairsStreaming(
        bufferSize: Int = 1000
    ) -> AsyncStream<DocumentPair> {
        let bands = self.bands
        let buckets = self.buckets

        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            Task {
                var seen = Set<DocumentPair>()

                for band in 0..<bands {
                    for (_, docIds) in buckets[band] {
                        for pair in docIds.combinations(ofCount: 2) {
                            let documentPair = DocumentPair(id1: pair[0], id2: pair[1])

                            // Deduplicate on the fly
                            if seen.insert(documentPair).inserted {
                                continuation.yield(documentPair)
                            }
                        }
                    }
                }

                continuation.finish()
            }
        }
    }

    /// Find candidate pairs based on parallel mode.
    ///
    /// - Parameter mode: The parallel execution mode.
    /// - Returns: Set of candidate document pairs.
    public func findCandidatePairs(mode: ParallelMode) async -> Set<DocumentPair> {
        switch mode {
        case .none:
            return findCandidatePairs()

        case .safe:
            return await findCandidatePairsParallel()

        case .maximum:
            // Streaming collects into Set for compatibility
            var candidates = Set<DocumentPair>()
            for await pair in findCandidatePairsStreaming() {
                candidates.insert(pair)
            }
            return candidates
        }
    }

    // MARK: Private

    /// Hash buckets for each band. buckets[band][hash] = [documentIds].
    private var buckets: [[UInt64: [Int]]]

    /// All indexed signatures.
    private var signatures: [Int: MinHashSignature]

    // MARK: - Private Helpers

    /// Hash a band of the signature.
    private func hashBand(signature: MinHashSignature, band: Int) -> UInt64 {
        let start = band * rows
        let end = min(start + rows, signature.values.count)

        // FNV-1a hash of the band values
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        for i in start..<end {
            hash ^= signature.values[i]
            hash = hash &* prime
        }

        return hash
    }
}

// MARK: - DocumentPair

/// A pair of document IDs.
public struct DocumentPair: Sendable, Hashable {
    // MARK: Lifecycle

    public init(id1: Int, id2: Int) {
        // Normalize order for consistent hashing
        if id1 < id2 {
            self.id1 = id1
            self.id2 = id2
        } else {
            self.id1 = id2
            self.id2 = id1
        }
    }

    // MARK: Public

    public let id1: Int
    public let id2: Int
}

// MARK: - SimilarPair

/// Result of LSH similarity search.
public struct SimilarPair: Sendable {
    // MARK: Lifecycle

    public init(documentId1: Int, documentId2: Int, similarity: Double) {
        self.documentId1 = min(documentId1, documentId2)
        self.documentId2 = max(documentId1, documentId2)
        self.similarity = similarity
    }

    // MARK: Public

    /// First document ID.
    public let documentId1: Int

    /// Second document ID.
    public let documentId2: Int

    /// Estimated Jaccard similarity.
    public let similarity: Double
}

// MARK: - LSHPipeline

/// Complete LSH pipeline for finding similar documents.
public struct LSHPipeline: Sendable {
    // MARK: Lifecycle

    public init(
        numHashes: Int = 128,
        threshold: Double = 0.5,
        seed: UInt64 = 42,
    ) {
        minHashGenerator = MinHashGenerator(numHashes: numHashes, seed: seed)
        let (b, r) = LSHIndex.optimalBandsAndRows(signatureSize: numHashes, threshold: threshold)
        bands = b
        rows = r
        self.threshold = threshold
    }

    // MARK: Public

    /// MinHash generator.
    public let minHashGenerator: MinHashGenerator

    /// LSH index parameters.
    public let bands: Int
    public let rows: Int

    /// Similarity threshold.
    public let threshold: Double

    /// Find similar pairs among documents.
    ///
    /// - Parameters:
    ///   - documents: Array of shingled documents.
    ///   - verifyWithExact: Whether to verify candidates with exact Jaccard.
    /// - Returns: Array of similar pairs above threshold.
    public func findSimilarPairs(
        _ documents: [ShingledDocument],
        verifyWithExact: Bool = false,
    ) -> [SimilarPair] {
        // Compute signatures
        let signatures = minHashGenerator.computeSignatures(for: documents)

        // Build index
        var index = LSHIndex(bands: bands, rows: rows)
        index.insert(signatures)

        // Find candidates
        let candidatePairs = index.findCandidatePairs()

        // Verify and filter using shared logic
        return CandidateVerifier.verify(
            candidatePairs: candidatePairs,
            index: index,
            documents: documents,
            threshold: threshold,
            verifyWithExact: verifyWithExact
        )
    }
}
