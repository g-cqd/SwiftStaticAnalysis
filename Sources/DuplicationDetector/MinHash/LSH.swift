//
//  LSH.swift
//  SwiftStaticAnalysis
//
//  Locality Sensitive Hashing (LSH) for efficient similarity search.
//
//  LSH uses the banding technique to bucket MinHash signatures so that
//  similar documents hash to the same bucket with high probability.
//  This reduces similarity search from O(n²) to approximately O(n).
//
//  The probability that two documents with Jaccard similarity s become
//  candidates is: 1 - (1 - s^r)^b
//  where b = number of bands, r = rows per band.
//

import Foundation

// MARK: - LSH Query Protocol

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
        threshold: Double = 0.0
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

// MARK: - LSH Index

/// Locality Sensitive Hashing index for efficient similarity search.
public struct LSHIndex: Sendable, LSHQueryable {
    /// Number of bands.
    public let bands: Int

    /// Rows per band.
    public let rows: Int

    /// Hash buckets for each band. buckets[band][hash] = [documentIds].
    private var buckets: [[UInt64: [Int]]]

    /// All indexed signatures.
    private var signatures: [Int: MinHashSignature]

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
        self.buckets = Array(repeating: [:], count: bands)
        self.signatures = [:]
    }

    /// Create an LSH index optimized for a target similarity threshold.
    ///
    /// - Parameters:
    ///   - signatureSize: Size of MinHash signatures.
    ///   - threshold: Target Jaccard similarity threshold (0.0 to 1.0).
    public init(signatureSize: Int, threshold: Double) {
        let (b, r) = Self.optimalBandsAndRows(signatureSize: signatureSize, threshold: threshold)
        self.bands = b
        self.rows = r
        self.buckets = Array(repeating: [:], count: b)
        self.signatures = [:]
    }

    /// Compute optimal bands and rows for a given threshold.
    ///
    /// The threshold where probability of becoming candidate is 0.5 is:
    /// t ≈ (1/b)^(1/r)
    ///
    /// - Parameters:
    ///   - signatureSize: Size of MinHash signatures.
    ///   - threshold: Target Jaccard similarity threshold.
    /// - Returns: Tuple of (bands, rows).
    public static func optimalBandsAndRows(
        signatureSize: Int,
        threshold: Double
    ) -> (bands: Int, rows: Int) {
        var bestBands = 1
        var bestRows = signatureSize
        var bestError = Double.infinity

        // Search for b, r such that n = b * r and threshold ≈ (1/b)^(1/r)
        for b in 1...signatureSize {
            let r = signatureSize / b
            guard r > 0 && b * r <= signatureSize else { continue }

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
                for i in 0..<docIds.count {
                    for j in (i + 1)..<docIds.count {
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

    // MARK: - Private Helpers

    /// Hash a band of the signature.
    private func hashBand(signature: MinHashSignature, band: Int) -> UInt64 {
        let start = band * rows
        let end = min(start + rows, signature.values.count)

        // FNV-1a hash of the band values
        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211

        for i in start..<end {
            hash ^= signature.values[i]
            hash = hash &* prime
        }

        return hash
    }
}

// MARK: - Document Pair

/// A pair of document IDs.
public struct DocumentPair: Sendable, Hashable {
    public let id1: Int
    public let id2: Int

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
}

// MARK: - Similar Pair Result

/// Result of LSH similarity search.
public struct SimilarPair: Sendable {
    /// First document ID.
    public let documentId1: Int

    /// Second document ID.
    public let documentId2: Int

    /// Estimated Jaccard similarity.
    public let similarity: Double

    public init(documentId1: Int, documentId2: Int, similarity: Double) {
        self.documentId1 = min(documentId1, documentId2)
        self.documentId2 = max(documentId1, documentId2)
        self.similarity = similarity
    }
}

// MARK: - LSH Pipeline

/// Complete LSH pipeline for finding similar documents.
public struct LSHPipeline: Sendable {
    /// MinHash generator.
    public let minHashGenerator: MinHashGenerator

    /// LSH index parameters.
    public let bands: Int
    public let rows: Int

    /// Similarity threshold.
    public let threshold: Double

    public init(
        numHashes: Int = 128,
        threshold: Double = 0.5,
        seed: UInt64 = 42
    ) {
        self.minHashGenerator = MinHashGenerator(numHashes: numHashes, seed: seed)
        let (b, r) = LSHIndex.optimalBandsAndRows(signatureSize: numHashes, threshold: threshold)
        self.bands = b
        self.rows = r
        self.threshold = threshold
    }

    /// Find similar pairs among documents.
    ///
    /// - Parameters:
    ///   - documents: Array of shingled documents.
    ///   - verifyWithExact: Whether to verify candidates with exact Jaccard.
    /// - Returns: Array of similar pairs above threshold.
    public func findSimilarPairs(
        _ documents: [ShingledDocument],
        verifyWithExact: Bool = false
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

            let similarity: Double
            if verifyWithExact, let doc1 = documentMap[pair.id1], let doc2 = documentMap[pair.id2] {
                similarity = MinHashGenerator.exactJaccardSimilarity(doc1, doc2)
            } else {
                similarity = sig1.estimateSimilarity(with: sig2)
            }

            if similarity >= threshold {
                results.append(SimilarPair(
                    documentId1: pair.id1,
                    documentId2: pair.id2,
                    similarity: similarity
                ))
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }
}

// MARK: - Multi-Probe LSH

/// Multi-probe LSH for improved recall without increasing index size.
///
/// Standard LSH may miss some similar pairs due to hash collisions.
/// Multi-probe queries multiple nearby buckets to improve recall by
/// probing perturbations of the original hash values.
///
/// The key insight is that similar documents may hash to slightly different
/// buckets. By probing nearby buckets (obtained by perturbing hash values),
/// we can find additional candidates without increasing index size.
public struct MultiProbeLSH: Sendable, LSHQueryable {
    /// Base LSH index.
    private var baseIndex: LSHIndex

    /// Number of bands.
    public var bands: Int { baseIndex.bands }

    /// Rows per band.
    public var rows: Int { baseIndex.rows }

    /// Number of probes per band.
    public let probesPerBand: Int

    /// Total number of additional probes.
    public let totalProbes: Int

    /// Perturbation vectors for each probe.
    private let perturbationVectors: [PerturbationVector]

    /// All indexed signatures (for similarity computation).
    private var signatures: [Int: MinHashSignature]

    public init(bands: Int, rows: Int, probesPerBand: Int = 2) {
        self.baseIndex = LSHIndex(bands: bands, rows: rows)
        self.probesPerBand = probesPerBand
        self.totalProbes = bands * probesPerBand
        self.signatures = [:]

        // Pre-compute perturbation vectors
        self.perturbationVectors = Self.generatePerturbationVectors(
            bands: bands,
            rows: rows,
            probesPerBand: probesPerBand
        )
    }

    /// Create from an existing LSH index.
    public init(index: LSHIndex, probesPerBand: Int = 2) {
        self.baseIndex = index
        self.probesPerBand = probesPerBand
        self.totalProbes = index.bands * probesPerBand
        self.signatures = [:]

        self.perturbationVectors = Self.generatePerturbationVectors(
            bands: index.bands,
            rows: index.rows,
            probesPerBand: probesPerBand
        )
    }

    /// Index a signature.
    public mutating func insert(_ signature: MinHashSignature) {
        baseIndex.insert(signature)
        signatures[signature.documentId] = signature
    }

    /// Index multiple signatures.
    public mutating func insert(_ sigs: [MinHashSignature]) {
        for sig in sigs {
            insert(sig)
        }
    }

    /// Query with multiple probes for improved recall.
    ///
    /// - Parameter signature: The query signature.
    /// - Returns: Set of candidate document IDs.
    public func query(_ signature: MinHashSignature) -> Set<Int> {
        var candidates = baseIndex.query(signature)

        // Add candidates from probed buckets
        for perturbation in perturbationVectors {
            let probedCandidates = queryWithPerturbation(signature, perturbation: perturbation)
            candidates.formUnion(probedCandidates)
        }

        // Remove self if present
        candidates.remove(signature.documentId)

        return candidates
    }

    /// Get the signature for a document ID.
    public func signature(for documentId: Int) -> MinHashSignature? {
        signatures[documentId]
    }

    /// Find all similar pairs using multi-probe LSH.
    ///
    /// - Parameter threshold: Minimum similarity threshold.
    /// - Returns: Array of similar pairs.
    public func findSimilarPairs(threshold: Double = 0.5) -> [SimilarPair] {
        var pairs = Set<DocumentPair>()

        // Get candidate pairs from base index
        let basePairs = baseIndex.findCandidatePairs()
        pairs.formUnion(basePairs)

        // Add pairs from multi-probe queries
        for (docId, signature) in signatures {
            for perturbation in perturbationVectors {
                let probedCandidates = queryWithPerturbation(signature, perturbation: perturbation)
                for candidateId in probedCandidates {
                    if candidateId != docId {
                        pairs.insert(DocumentPair(id1: docId, id2: candidateId))
                    }
                }
            }
        }

        // Filter by threshold
        var results: [SimilarPair] = []
        for pair in pairs {
            guard let sig1 = signatures[pair.id1],
                  let sig2 = signatures[pair.id2] else { continue }

            let similarity = sig1.estimateSimilarity(with: sig2)
            if similarity >= threshold {
                results.append(SimilarPair(
                    documentId1: pair.id1,
                    documentId2: pair.id2,
                    similarity: similarity
                ))
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Private Helpers

    /// Query with a perturbed signature.
    private func queryWithPerturbation(
        _ signature: MinHashSignature,
        perturbation: PerturbationVector
    ) -> Set<Int> {
        // Apply perturbation to create modified signature
        let perturbedSignature = applyPerturbation(signature, perturbation: perturbation)

        // Query with the perturbed signature
        return baseIndex.query(perturbedSignature)
    }

    /// Apply a perturbation vector to a signature.
    private func applyPerturbation(
        _ signature: MinHashSignature,
        perturbation: PerturbationVector
    ) -> MinHashSignature {
        var values = signature.values

        // Apply perturbations
        for (index, delta) in perturbation.deltas {
            if index < values.count {
                // Modify the value by the delta
                values[index] = values[index] &+ delta
            }
        }

        return MinHashSignature(values: values, documentId: signature.documentId)
    }

    /// Generate perturbation vectors for multi-probe.
    ///
    /// Perturbation vectors modify specific positions in the signature
    /// to probe nearby hash buckets.
    private static func generatePerturbationVectors(
        bands: Int,
        rows: Int,
        probesPerBand: Int
    ) -> [PerturbationVector] {
        var vectors: [PerturbationVector] = []

        for band in 0..<bands {
            let bandStart = band * rows

            for probe in 0..<probesPerBand {
                var deltas: [(index: Int, delta: UInt64)] = []

                // For each probe, perturb positions within the band
                // Use different perturbation strategies for each probe
                for row in 0..<min(probe + 1, rows) {
                    let index = bandStart + row
                    // Use incrementing deltas for variety
                    let delta = UInt64(probe + 1)
                    deltas.append((index, delta))
                }

                vectors.append(PerturbationVector(
                    band: band,
                    deltas: deltas
                ))
            }
        }

        return vectors
    }
}

// MARK: - Perturbation Vector

/// A perturbation vector for multi-probe LSH.
struct PerturbationVector: Sendable {
    /// The band this perturbation is for.
    let band: Int

    /// Position-delta pairs for perturbation.
    let deltas: [(index: Int, delta: UInt64)]
}

// MARK: - LSH Index Extension for Multi-Probe Support

extension LSHIndex {
    /// Query with multiple probes for improved recall.
    ///
    /// - Parameters:
    ///   - signature: The query signature.
    ///   - probes: Number of additional probes per band.
    /// - Returns: Set of candidate document IDs.
    public func queryMultiProbe(
        _ signature: MinHashSignature,
        probes: Int = 3
    ) -> Set<Int> {
        guard signature.values.count >= bands * rows else { return [] }

        var candidates = Set<Int>()

        // Original query
        candidates.formUnion(query(signature))

        // Generate and query perturbations
        let perturbations = generatePerturbations(signature, count: probes)
        for perturbed in perturbations {
            candidates.formUnion(query(perturbed))
        }

        // Remove self if present
        candidates.remove(signature.documentId)

        return candidates
    }

    /// Query with multi-probe and rank results by similarity.
    ///
    /// - Parameters:
    ///   - signature: The query signature.
    ///   - probes: Number of additional probes per band.
    ///   - threshold: Minimum similarity to include.
    /// - Returns: Array of (documentId, similarity) pairs, sorted by similarity.
    public func queryMultiProbeWithSimilarity(
        _ signature: MinHashSignature,
        probes: Int = 3,
        threshold: Double = 0.0
    ) -> [(documentId: Int, similarity: Double)] {
        let candidates = queryMultiProbe(signature, probes: probes)

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

    /// Generate perturbation signatures for multi-probe.
    private func generatePerturbations(
        _ signature: MinHashSignature,
        count: Int
    ) -> [MinHashSignature] {
        var perturbations: [MinHashSignature] = []

        for bandIndex in 0..<min(count, bands) {
            var perturbed = signature.values
            // Perturb one value in this band
            let offset = bandIndex * rows
            if offset < perturbed.count {
                perturbed[offset] = perturbed[offset] &+ 1
            }
            perturbations.append(MinHashSignature(
                values: perturbed,
                documentId: signature.documentId
            ))

            // Also try subtracting
            var perturbed2 = signature.values
            if offset < perturbed2.count {
                perturbed2[offset] = perturbed2[offset] &- 1
            }
            perturbations.append(MinHashSignature(
                values: perturbed2,
                documentId: signature.documentId
            ))
        }

        return perturbations
    }
}

// MARK: - Multi-Probe LSH Pipeline

/// Complete multi-probe LSH pipeline for finding similar documents.
public struct MultiProbeLSHPipeline: Sendable {
    /// MinHash generator.
    public let minHashGenerator: MinHashGenerator

    /// Number of bands.
    public let bands: Int

    /// Rows per band.
    public let rows: Int

    /// Probes per band for multi-probe.
    public let probesPerBand: Int

    /// Similarity threshold.
    public let threshold: Double

    public init(
        numHashes: Int = 128,
        threshold: Double = 0.5,
        probesPerBand: Int = 2,
        seed: UInt64 = 42
    ) {
        self.minHashGenerator = MinHashGenerator(numHashes: numHashes, seed: seed)
        let (b, r) = LSHIndex.optimalBandsAndRows(signatureSize: numHashes, threshold: threshold)
        self.bands = b
        self.rows = r
        self.probesPerBand = probesPerBand
        self.threshold = threshold
    }

    /// Find similar pairs using multi-probe LSH.
    ///
    /// - Parameters:
    ///   - documents: Array of shingled documents.
    ///   - verifyWithExact: Whether to verify candidates with exact Jaccard.
    /// - Returns: Array of similar pairs above threshold.
    public func findSimilarPairs(
        _ documents: [ShingledDocument],
        verifyWithExact: Bool = false
    ) -> [SimilarPair] {
        // Compute signatures
        let signatures = minHashGenerator.computeSignatures(for: documents)

        // Build multi-probe index
        var index = MultiProbeLSH(bands: bands, rows: rows, probesPerBand: probesPerBand)
        index.insert(signatures)

        // Find similar pairs using multi-probe
        var results = index.findSimilarPairs(threshold: threshold)

        // Optionally verify with exact Jaccard
        if verifyWithExact {
            let documentMap = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

            results = results.compactMap { pair in
                guard let doc1 = documentMap[pair.documentId1],
                      let doc2 = documentMap[pair.documentId2] else { return nil }

                let exactSimilarity = MinHashGenerator.exactJaccardSimilarity(doc1, doc2)
                if exactSimilarity >= threshold {
                    return SimilarPair(
                        documentId1: pair.documentId1,
                        documentId2: pair.documentId2,
                        similarity: exactSimilarity
                    )
                }
                return nil
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }

    /// Find similar documents to a query.
    ///
    /// - Parameters:
    ///   - query: The query document.
    ///   - documents: Documents to search.
    /// - Returns: Array of (documentId, similarity) pairs.
    public func findSimilar(
        to query: ShingledDocument,
        in documents: [ShingledDocument]
    ) -> [(documentId: Int, similarity: Double)] {
        // Compute signatures
        var allDocs = documents
        allDocs.append(query)
        let signatures = minHashGenerator.computeSignatures(for: allDocs)

        // Build index
        var index = MultiProbeLSH(bands: bands, rows: rows, probesPerBand: probesPerBand)
        index.insert(signatures)

        // Query
        guard let querySig = signatures.first(where: { $0.documentId == query.id }) else {
            return []
        }

        return index.queryWithSimilarity(querySig, threshold: threshold)
    }
}
