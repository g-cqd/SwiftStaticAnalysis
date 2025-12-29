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

import Foundation

// MARK: - LSHQueryable

/// Protocol for LSH indices that can query for similar documents.
public protocol LSHQueryable: Sendable {
    /// Query for candidate documents similar to the given signature.
    func query(_ signature: MinHashSignature) -> Set<Int>

    /// Get the signature for a document ID.
    func signature(for documentId: Int) -> MinHashSignature?
}

public extension LSHQueryable {
    /// Query and rank results by similarity.
    ///
    /// - Parameters:
    ///   - signature: The query signature.
    ///   - threshold: Minimum similarity to include.
    /// - Returns: Array of (documentId, similarity) pairs, sorted by similarity.
    func queryWithSimilarity(
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
        for b in 1 ... signatureSize {
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
        for band in 0 ..< bands {
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

        for band in 0 ..< bands {
            for (_, docIds) in buckets[band] {
                // All pairs in the same bucket are candidates
                for i in 0 ..< docIds.count {
                    for j in (i + 1) ..< docIds.count {
                        let pair = DocumentPair(id1: docIds[i], id2: docIds[j])
                        candidates.insert(pair)
                    }
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

        for band in 0 ..< bands {
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

        for i in start ..< end {
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

        // Build document lookup
        let documentMap = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        // Verify and filter
        var results: [SimilarPair] = []
        for pair in candidatePairs {
            guard let sig1 = index.signature(for: pair.id1),
                  let sig2 = index.signature(for: pair.id2) else { continue }

            let similarity: Double = if verifyWithExact, let doc1 = documentMap[pair.id1],
                                        let doc2 = documentMap[pair.id2] {
                MinHashGenerator.exactJaccardSimilarity(doc1, doc2)
            } else {
                sig1.estimateSimilarity(with: sig2)
            }

            if similarity >= threshold {
                results.append(SimilarPair(
                    documentId1: pair.id1,
                    documentId2: pair.id2,
                    similarity: similarity,
                ))
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }
}
