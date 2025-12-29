//
//  MinHashCloneDetector.swift
//  SwiftStaticAnalysis
//
//  Clone detection using MinHash and LSH for Type-3 (gapped/near-miss) clones.
//
//  This detector uses probabilistic similarity estimation to find code clones
//  that may have insertions, deletions, or modifications. It achieves O(n)
//  complexity by using LSH to avoid O(n²) pairwise comparisons.
//

import Foundation

// MARK: - MinHashCloneDetector

/// Detects Type-3 clones using MinHash and LSH.
public struct MinHashCloneDetector: Sendable {
    // MARK: Lifecycle

    public init(
        minimumTokens: Int = 50,
        shingleSize: Int = 5,
        numHashes: Int = 128,
        minimumSimilarity: Double = 0.5,
    ) {
        self.minimumTokens = minimumTokens
        self.shingleSize = shingleSize
        self.numHashes = numHashes
        self.minimumSimilarity = minimumSimilarity

        shingleGenerator = ShingleGenerator(shingleSize: shingleSize, normalize: true)
        minHashGenerator = MinHashGenerator(numHashes: numHashes)

        // Calculate optimal LSH parameters for the threshold
        let (b, r) = LSHIndex.optimalBandsAndRows(
            signatureSize: numHashes,
            threshold: minimumSimilarity,
        )
        lshBands = b
        lshRows = r
    }

    // MARK: Public

    /// Minimum tokens to consider as a clone.
    public let minimumTokens: Int

    /// Shingle size for n-gram generation.
    public let shingleSize: Int

    /// Number of hash functions for MinHash.
    public let numHashes: Int

    /// Minimum similarity threshold for clones.
    public let minimumSimilarity: Double

    /// Detect Type-3 clones in the given token sequences.
    ///
    /// - Parameter sequences: Array of token sequences from files.
    /// - Returns: Array of clone groups found.
    public func detect(in sequences: [TokenSequence]) -> [CloneGroup] {
        // Generate shingled documents for all code blocks
        var allDocuments: [ShingledDocument] = []
        var documentId = 0

        for sequence in sequences {
            let documents = shingleGenerator.generateBlockDocuments(
                from: sequence,
                blockSize: minimumTokens,
                startId: documentId,
            )
            allDocuments.append(contentsOf: documents)
            documentId += documents.count
        }

        guard !allDocuments.isEmpty else { return [] }

        // Compute MinHash signatures
        let signatures = minHashGenerator.computeSignatures(for: allDocuments)

        // Build LSH index
        var lshIndex = LSHIndex(bands: lshBands, rows: lshRows)
        lshIndex.insert(signatures)

        // Find candidate pairs
        let candidatePairs = lshIndex.findCandidatePairs()

        // Build document lookup
        let documentMap = Dictionary(uniqueKeysWithValues: allDocuments.map { ($0.id, $0) })

        // Verify candidates and build clone groups
        var clonePairs: [(doc1: ShingledDocument, doc2: ShingledDocument, similarity: Double)] = []

        for pair in candidatePairs {
            guard let doc1 = documentMap[pair.id1],
                  let doc2 = documentMap[pair.id2] else { continue }

            // Skip if same file and overlapping lines
            if doc1.file == doc2.file {
                let overlaps = !(doc1.endLine < doc2.startLine || doc2.endLine < doc1.startLine)
                if overlaps {
                    continue
                }
            }

            // Compute exact Jaccard similarity for verification
            let similarity = MinHashGenerator.exactJaccardSimilarity(doc1, doc2)

            if similarity >= minimumSimilarity {
                clonePairs.append((doc1, doc2, similarity))
            }
        }

        // Group related clones
        return groupClones(clonePairs)
    }

    /// Detect clones with file path inputs.
    ///
    /// - Parameter files: Array of Swift file paths.
    /// - Returns: Array of clone groups found.
    public func detect(in files: [String]) async throws -> [CloneGroup] {
        let parser = SwiftFileParser()
        let extractor = TokenSequenceExtractor()
        var sequences: [TokenSequence] = []

        for file in files {
            let tree = try await parser.parse(file)
            let source = try String(contentsOfFile: file, encoding: .utf8)
            let sequence = extractor.extract(from: tree, file: file, source: source)
            sequences.append(sequence)
        }

        return detect(in: sequences)
    }

    // MARK: Private

    /// Shingle generator.
    private let shingleGenerator: ShingleGenerator

    /// MinHash generator.
    private let minHashGenerator: MinHashGenerator

    /// LSH bands and rows.
    private let lshBands: Int
    private let lshRows: Int

    // MARK: - Private Helpers

    /// Group clone pairs into clone groups.
    private func groupClones(
        _ pairs: [(doc1: ShingledDocument, doc2: ShingledDocument, similarity: Double)],
    ) -> [CloneGroup] {
        guard !pairs.isEmpty else { return [] }

        // Build adjacency list for transitive closure
        var adjacency: [Int: Set<Int>] = [:]
        var documentInfo: [Int: (file: String, startLine: Int, endLine: Int, tokenCount: Int)] = [:]

        for (doc1, doc2, _) in pairs {
            adjacency[doc1.id, default: []].insert(doc2.id)
            adjacency[doc2.id, default: []].insert(doc1.id)
            documentInfo[doc1.id] = (doc1.file, doc1.startLine, doc1.endLine, doc1.tokenCount)
            documentInfo[doc2.id] = (doc2.file, doc2.startLine, doc2.endLine, doc2.tokenCount)
        }

        // Find connected components using BFS
        var visited = Set<Int>()
        var groups: [[Int]] = []

        for docId in adjacency.keys {
            guard !visited.contains(docId) else { continue }

            var component: [Int] = []
            var queue = [docId]
            visited.insert(docId)

            while !queue.isEmpty {
                let current = queue.removeFirst()
                component.append(current)

                if let neighbors = adjacency[current] {
                    for neighbor in neighbors where !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        queue.append(neighbor)
                    }
                }
            }

            if component.count >= 2 {
                groups.append(component)
            }
        }

        // Convert to CloneGroups
        return groups.compactMap { component -> CloneGroup? in
            let clones = component.compactMap { docId -> Clone? in
                guard let info = documentInfo[docId] else { return nil }
                return Clone(
                    file: info.file,
                    startLine: info.startLine,
                    endLine: info.endLine,
                    tokenCount: info.tokenCount,
                    codeSnippet: "",
                )
            }

            guard clones.count >= 2 else { return nil }

            // Calculate average similarity within group
            let groupPairs = pairs.filter { pair in
                component.contains(pair.doc1.id) && component.contains(pair.doc2.id)
            }
            let avgSimilarity = groupPairs.isEmpty ? minimumSimilarity :
                groupPairs.reduce(0.0) { $0 + $1.similarity } / Double(groupPairs.count)

            // Generate fingerprint from document IDs
            let fingerprint = component.sorted().map(String.init).joined(separator: "-")

            return CloneGroup(
                type: .semantic, // Type-3 clones are reported as semantic
                clones: clones,
                similarity: avgSimilarity,
                fingerprint: fingerprint,
            )
        }
    }
}

// MARK: - FastSimilarityChecker

/// Fast similarity checking using MinHash without full LSH.
///
/// Useful for comparing a small number of specific code blocks.
public struct FastSimilarityChecker: Sendable {
    // MARK: Lifecycle

    public init(shingleSize: Int = 5, numHashes: Int = 128) {
        shingleGenerator = ShingleGenerator(shingleSize: shingleSize, normalize: true)
        minHashGenerator = MinHashGenerator(numHashes: numHashes)
    }

    // MARK: Public

    /// Estimate similarity between two token sequences.
    public func estimateSimilarity(
        _ tokens1: [String],
        kinds1: [TokenKind],
        _ tokens2: [String],
        kinds2: [TokenKind],
    ) -> Double {
        let shingles1 = shingleGenerator.generate(tokens: tokens1, kinds: kinds1)
        let shingles2 = shingleGenerator.generate(tokens: tokens2, kinds: kinds2)

        let hashes1 = Set(shingles1.map(\.hash))
        let hashes2 = Set(shingles2.map(\.hash))

        let sig1 = minHashGenerator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = minHashGenerator.computeSignature(for: hashes2, documentId: 1)

        return sig1.estimateSimilarity(with: sig2)
    }

    /// Compute exact Jaccard similarity.
    public func exactSimilarity(
        _ tokens1: [String],
        kinds1: [TokenKind],
        _ tokens2: [String],
        kinds2: [TokenKind],
    ) -> Double {
        let shingles1 = shingleGenerator.generate(tokens: tokens1, kinds: kinds1)
        let shingles2 = shingleGenerator.generate(tokens: tokens2, kinds: kinds2)

        let hashes1 = Set(shingles1.map(\.hash))
        let hashes2 = Set(shingles2.map(\.hash))

        return MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)
    }

    // MARK: Private

    /// Shingle generator.
    private let shingleGenerator: ShingleGenerator

    /// MinHash generator.
    private let minHashGenerator: MinHashGenerator
}

// MARK: - SwiftStaticAnalysisCore Import

import SwiftStaticAnalysisCore
