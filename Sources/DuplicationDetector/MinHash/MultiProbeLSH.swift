//
//  MultiProbeLSH.swift
//  SwiftStaticAnalysis
//
//  Multi-probe LSH for improved recall without increasing index size.
//

import Foundation

// MARK: - MultiProbeLSH

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
    // MARK: Lifecycle

    public init(bands: Int, rows: Int, probesPerBand: Int = 2) {
        baseIndex = LSHIndex(bands: bands, rows: rows)
        self.probesPerBand = probesPerBand
        totalProbes = bands * probesPerBand
        signatures = [:]

        // Pre-compute perturbation vectors
        perturbationVectors = Self.generatePerturbationVectors(
            bands: bands,
            rows: rows,
            probesPerBand: probesPerBand,
        )
    }

    /// Create from an existing LSH index.
    public init(index: LSHIndex, probesPerBand: Int = 2) {
        baseIndex = index
        self.probesPerBand = probesPerBand
        totalProbes = index.bands * probesPerBand
        signatures = [:]

        perturbationVectors = Self.generatePerturbationVectors(
            bands: index.bands,
            rows: index.rows,
            probesPerBand: probesPerBand,
        )
    }

    // MARK: Public

    /// Number of probes per band.
    public let probesPerBand: Int

    /// Total number of additional probes.
    public let totalProbes: Int

    /// Number of bands.
    public var bands: Int { baseIndex.bands }

    /// Rows per band.
    public var rows: Int { baseIndex.rows }

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
                for candidateId in probedCandidates where candidateId != docId {
                    pairs.insert(DocumentPair(id1: docId, id2: candidateId))
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
                    similarity: similarity,
                ))
            }
        }

        return results.sorted { $0.similarity > $1.similarity }
    }

    // MARK: Private

    /// Base LSH index.
    private var baseIndex: LSHIndex

    /// Perturbation vectors for each probe.
    private let perturbationVectors: [PerturbationVector]

    /// All indexed signatures (for similarity computation).
    private var signatures: [Int: MinHashSignature]

    /// Generate perturbation vectors for multi-probe.
    ///
    /// Perturbation vectors modify specific positions in the signature
    /// to probe nearby hash buckets.
    private static func generatePerturbationVectors(
        bands: Int,
        rows: Int,
        probesPerBand: Int,
    ) -> [PerturbationVector] {
        var vectors: [PerturbationVector] = []

        for band in 0 ..< bands {
            let bandStart = band * rows

            for probe in 0 ..< probesPerBand {
                var deltas: [(index: Int, delta: UInt64)] = []

                // For each probe, perturb positions within the band
                // Use different perturbation strategies for each probe
                for row in 0 ..< min(probe + 1, rows) {
                    let index = bandStart + row
                    // Use incrementing deltas for variety
                    let delta = UInt64(probe + 1)
                    deltas.append((index, delta))
                }

                vectors.append(PerturbationVector(
                    band: band,
                    deltas: deltas,
                ))
            }
        }

        return vectors
    }

    // MARK: - Private Helpers

    /// Query with a perturbed signature.
    private func queryWithPerturbation(
        _ signature: MinHashSignature,
        perturbation: PerturbationVector,
    ) -> Set<Int> {
        // Apply perturbation to create modified signature
        let perturbedSignature = applyPerturbation(signature, perturbation: perturbation)

        // Query with the perturbed signature
        return baseIndex.query(perturbedSignature)
    }

    /// Apply a perturbation vector to a signature.
    private func applyPerturbation(
        _ signature: MinHashSignature,
        perturbation: PerturbationVector,
    ) -> MinHashSignature {
        var values = signature.values

        // Apply perturbations
        for (index, delta) in perturbation.deltas where index < values.count {
            // Modify the value by the delta
            values[index] = values[index] &+ delta
        }

        return MinHashSignature(values: values, documentId: signature.documentId)
    }
}

// MARK: - PerturbationVector

/// A perturbation vector for multi-probe LSH.
struct PerturbationVector: Sendable {
    /// The band this perturbation is for.
    let band: Int

    /// Position-delta pairs for perturbation.
    let deltas: [(index: Int, delta: UInt64)]
}

// MARK: - LSH Index Extension for Multi-Probe Support

public extension LSHIndex {
    /// Query with multiple probes for improved recall.
    ///
    /// - Parameters:
    ///   - signature: The query signature.
    ///   - probes: Number of additional probes per band.
    /// - Returns: Set of candidate document IDs.
    func queryMultiProbe(
        _ signature: MinHashSignature,
        probes: Int = 3,
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
    func queryMultiProbeWithSimilarity(
        _ signature: MinHashSignature,
        probes: Int = 3,
        threshold: Double = 0.0,
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
        count: Int,
    ) -> [MinHashSignature] {
        var perturbations: [MinHashSignature] = []

        for bandIndex in 0 ..< min(count, bands) {
            var perturbed = signature.values
            // Perturb one value in this band
            let offset = bandIndex * rows
            if offset < perturbed.count {
                perturbed[offset] = perturbed[offset] &+ 1
            }
            perturbations.append(MinHashSignature(
                values: perturbed,
                documentId: signature.documentId,
            ))

            // Also try subtracting
            var perturbed2 = signature.values
            if offset < perturbed2.count {
                perturbed2[offset] = perturbed2[offset] &- 1
            }
            perturbations.append(MinHashSignature(
                values: perturbed2,
                documentId: signature.documentId,
            ))
        }

        return perturbations
    }
}

// MARK: - MultiProbeLSHPipeline

/// Complete multi-probe LSH pipeline for finding similar documents.
public struct MultiProbeLSHPipeline: Sendable {
    // MARK: Lifecycle

    public init(
        numHashes: Int = 128,
        threshold: Double = 0.5,
        probesPerBand: Int = 2,
        seed: UInt64 = 42,
    ) {
        minHashGenerator = MinHashGenerator(numHashes: numHashes, seed: seed)
        let (b, r) = LSHIndex.optimalBandsAndRows(signatureSize: numHashes, threshold: threshold)
        bands = b
        rows = r
        self.probesPerBand = probesPerBand
        self.threshold = threshold
    }

    // MARK: Public

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

    /// Find similar pairs using multi-probe LSH.
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
                        similarity: exactSimilarity,
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
        in documents: [ShingledDocument],
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
