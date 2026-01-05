//
//  CandidateVerifier.swift
//  SwiftStaticAnalysis
//
//  Shared verification logic for LSH candidate pairs.
//  Extracted from LSH and ParallelLSH to eliminate code duplication.
//

import Algorithms
import Foundation

// MARK: - CandidateVerifier

/// Shared verification logic for LSH candidate pairs.
public enum CandidateVerifier {
    /// Verify candidate pairs and filter by similarity threshold.
    ///
    /// - Parameters:
    ///   - candidatePairs: The candidate pairs from LSH.
    ///   - index: The LSH index containing signatures.
    ///   - documents: The original shingled documents.
    ///   - threshold: Minimum similarity threshold.
    ///   - verifyWithExact: Whether to verify using exact Jaccard similarity.
    /// - Returns: Array of similar pairs above threshold, sorted by similarity descending.
    public static func verify(
        candidatePairs: Set<DocumentPair>,
        index: LSHIndex,
        documents: [ShingledDocument],
        threshold: Double,
        verifyWithExact: Bool
    ) -> [SimilarPair] {
        // Build document lookup
        let documentMap = documents.keyed(by: \.id)

        // Verify and filter
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
