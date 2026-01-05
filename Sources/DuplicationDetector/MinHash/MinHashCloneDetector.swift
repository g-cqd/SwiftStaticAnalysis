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

import Algorithms
import Collections
import Foundation
import SwiftStaticAnalysisCore
import UnusedCodeDetector  // For AtomicBitmap, Bitmap

// MARK: - ClonePairInfo

/// Information about a pair of similar documents.
public struct ClonePairInfo: Sendable {
    let doc1: ShingledDocument
    let doc2: ShingledDocument
    let similarity: Double
}

// MARK: - DocumentLocationInfo

/// Location information for a document.
struct DocumentLocationInfo: Sendable {
    let file: String
    let startLine: Int
    let endLine: Int
    let tokenCount: Int
}

// MARK: - ParallelCloneConfiguration

/// Configuration for parallel clone detection.
public struct ParallelCloneConfiguration: Sendable {
    // MARK: Lifecycle

    /// Create parallel clone configuration.
    ///
    /// - Parameters:
    ///   - enabled: Whether to enable parallel processing.
    ///   - minParallelDocuments: Minimum documents to trigger parallelism.
    ///   - minParallelPairs: Minimum pairs to trigger parallel verification.
    ///   - maxConcurrency: Maximum concurrent tasks.
    public init(
        enabled: Bool = true,
        minParallelDocuments: Int = 50,
        minParallelPairs: Int = 100,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.enabled = enabled
        self.minParallelDocuments = max(1, minParallelDocuments)
        self.minParallelPairs = max(1, minParallelPairs)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    // MARK: Public

    /// Default configuration (parallel enabled).
    public static let `default` = ParallelCloneConfiguration()

    /// Sequential-only configuration.
    public static let sequential = ParallelCloneConfiguration(enabled: false)

    /// Whether to enable parallel processing.
    public let enabled: Bool

    /// Minimum documents to trigger parallel MinHash.
    public let minParallelDocuments: Int

    /// Minimum pairs to trigger parallel verification.
    public let minParallelPairs: Int

    /// Maximum concurrent tasks.
    public let maxConcurrency: Int
}

// MARK: - MinHashCloneDetector

/// Detects Type-3 clones using MinHash and LSH.
public struct MinHashCloneDetector: Sendable {
    // MARK: Lifecycle

    public init(
        minimumTokens: Int = 50,
        shingleSize: Int = 5,
        numHashes: Int = 128,
        minimumSimilarity: Double = 0.5,
        parallelConfig: ParallelCloneConfiguration = .default
    ) {
        self.minimumTokens = minimumTokens
        self.shingleSize = shingleSize
        self.numHashes = numHashes
        self.minimumSimilarity = minimumSimilarity
        self.parallelConfig = parallelConfig

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

    /// Parallel processing configuration.
    public let parallelConfig: ParallelCloneConfiguration

    /// Detect Type-3 clones in the given token sequences.
    ///
    /// - Parameter sequences: Array of token sequences from files.
    /// - Returns: Array of clone groups found.
    public func detect(in sequences: [TokenSequence]) -> [CloneGroup] {
        // Safety: ensure minimumTokens is valid
        guard !sequences.isEmpty, minimumTokens > 0 else { return [] }

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
        let documentMap = allDocuments.keyed(by: \.id)

        // Verify candidates and build clone groups
        let clonePairs = verifyCandidatePairs(candidatePairs, documentMap: documentMap)

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

        // Use parallel detection if enabled and enough documents
        if parallelConfig.enabled {
            return await detectParallel(in: sequences)
        }
        return detect(in: sequences)
    }

    /// Detect Type-3 clones using parallel processing.
    ///
    /// Uses parallel MinHash, parallel LSH candidate finding, parallel verification,
    /// and parallel connected components for optimal performance on large codebases.
    ///
    /// - Parameter sequences: Array of token sequences from files.
    /// - Returns: Array of clone groups found.
    public func detectParallel(in sequences: [TokenSequence]) async -> [CloneGroup] {
        guard !sequences.isEmpty, minimumTokens > 0 else { return [] }

        // Generate shingled documents for all code blocks
        var allDocuments: [ShingledDocument] = []
        var documentId = 0

        for sequence in sequences {
            let documents = shingleGenerator.generateBlockDocuments(
                from: sequence,
                blockSize: minimumTokens,
                startId: documentId
            )
            allDocuments.append(contentsOf: documents)
            documentId += documents.count
        }

        guard !allDocuments.isEmpty else { return [] }

        // Decide between parallel and sequential based on document count
        let useParallelMinHash = allDocuments.count >= parallelConfig.minParallelDocuments

        // Compute MinHash signatures (parallel or sequential)
        let signatures: [MinHashSignature]
        if useParallelMinHash {
            let parallelMinHash = ParallelMinHashGenerator(
                numHashes: numHashes,
                maxConcurrency: parallelConfig.maxConcurrency
            )
            signatures = await parallelMinHash.computeSignatures(for: allDocuments)
        } else {
            signatures = minHashGenerator.computeSignatures(for: allDocuments)
        }

        // Build LSH index
        var lshIndex = LSHIndex(bands: lshBands, rows: lshRows)
        lshIndex.insert(signatures)

        // Find candidate pairs (parallel if enough bands)
        let candidatePairs: Set<DocumentPair>
        if lshBands >= 4 {
            candidatePairs = await lshIndex.findCandidatePairsParallel(
                maxConcurrency: parallelConfig.maxConcurrency
            )
        } else {
            candidatePairs = lshIndex.findCandidatePairs()
        }

        // Build document lookup
        let documentMap = allDocuments.keyed(by: \.id)

        // Verify candidates (parallel or sequential)
        let clonePairs: [ClonePairInfo]
        if candidatePairs.count >= parallelConfig.minParallelPairs {
            let verifier = ParallelVerifier(
                minimumSimilarity: minimumSimilarity,
                minParallelPairs: parallelConfig.minParallelPairs,
                maxConcurrency: parallelConfig.maxConcurrency
            )
            clonePairs = await verifier.verifyCandidatePairs(candidatePairs, documentMap: documentMap)
        } else {
            clonePairs = verifyCandidatePairs(candidatePairs, documentMap: documentMap)
        }

        // Group related clones using parallel connected components
        return await groupClonesParallel(clonePairs, maxDocId: documentId - 1)
    }

    // MARK: Private

    /// Shingle generator.
    private let shingleGenerator: ShingleGenerator

    /// MinHash generator.
    private let minHashGenerator: MinHashGenerator

    /// LSH bands and rows.
    private let lshBands: Int
    private let lshRows: Int

    /// Verify candidate pairs and filter by similarity threshold.
    private func verifyCandidatePairs(
        _ candidatePairs: Set<DocumentPair>,
        documentMap: [Int: ShingledDocument],
    ) -> [ClonePairInfo] {
        var clonePairs: [ClonePairInfo] = []

        for pair in candidatePairs {
            guard let doc1 = documentMap[pair.id1],
                let doc2 = documentMap[pair.id2]
            else { continue }

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
                clonePairs.append(ClonePairInfo(doc1: doc1, doc2: doc2, similarity: similarity))
            }
        }

        return clonePairs
    }

    // MARK: - Private Helpers

    /// Group clone pairs into clone groups.
    private func groupClones(_ pairs: [ClonePairInfo]) -> [CloneGroup] {
        guard !pairs.isEmpty else { return [] }

        // Build adjacency list and document info
        let (adjacency, documentInfo) = buildAdjacencyInfo(from: pairs)

        // Find connected components using BFS
        let groups = findConnectedComponents(adjacency: adjacency)

        // Convert to CloneGroups
        return convertToCloneGroups(groups, documentInfo: documentInfo, pairs: pairs)
    }

    /// Group clone pairs into clone groups using parallel connected components.
    ///
    /// - Parameters:
    ///   - pairs: Verified clone pairs.
    ///   - maxDocId: Maximum document ID for graph sizing.
    /// - Returns: Array of clone groups.
    private func groupClonesParallel(
        _ pairs: [ClonePairInfo],
        maxDocId: Int
    ) async -> [CloneGroup] {
        guard !pairs.isEmpty else { return [] }

        // Build document info for conversion
        var documentInfo: [Int: DocumentLocationInfo] = [:]
        for pair in pairs {
            documentInfo[pair.doc1.id] = DocumentLocationInfo(
                file: pair.doc1.file,
                startLine: pair.doc1.startLine,
                endLine: pair.doc1.endLine,
                tokenCount: pair.doc1.tokenCount
            )
            documentInfo[pair.doc2.id] = DocumentLocationInfo(
                file: pair.doc2.file,
                startLine: pair.doc2.startLine,
                endLine: pair.doc2.endLine,
                tokenCount: pair.doc2.tokenCount
            )
        }

        // Build dense graph from pairs
        let graph = CloneSimilarityGraph(pairs: pairs, maxDocId: maxDocId)

        // Find connected components using parallel BFS
        let config = ParallelConnectedComponents.Configuration(
            minParallelSize: parallelConfig.minParallelDocuments,
            maxConcurrency: parallelConfig.maxConcurrency
        )
        let groups = await ParallelConnectedComponents.findComponents(
            graph: graph,
            configuration: config
        )

        // Convert to CloneGroups
        return convertToCloneGroups(groups, documentInfo: documentInfo, pairs: pairs)
    }

    /// Build adjacency list and document info from pairs.
    private func buildAdjacencyInfo(
        from pairs: [ClonePairInfo],
    ) -> (adjacency: [Int: Set<Int>], documentInfo: [Int: DocumentLocationInfo]) {
        var adjacency: [Int: Set<Int>] = [:]
        var documentInfo: [Int: DocumentLocationInfo] = [:]

        for pair in pairs {
            adjacency[pair.doc1.id, default: []].insert(pair.doc2.id)
            adjacency[pair.doc2.id, default: []].insert(pair.doc1.id)
            documentInfo[pair.doc1.id] = DocumentLocationInfo(
                file: pair.doc1.file,
                startLine: pair.doc1.startLine,
                endLine: pair.doc1.endLine,
                tokenCount: pair.doc1.tokenCount,
            )
            documentInfo[pair.doc2.id] = DocumentLocationInfo(
                file: pair.doc2.file,
                startLine: pair.doc2.startLine,
                endLine: pair.doc2.endLine,
                tokenCount: pair.doc2.tokenCount,
            )
        }

        return (adjacency, documentInfo)
    }

    /// Find connected components using BFS.
    private func findConnectedComponents(adjacency: [Int: Set<Int>]) -> [[Int]] {
        var visited = Set<Int>()
        var groups: [[Int]] = []

        for docId in adjacency.keys where !visited.contains(docId) {
            var component: [Int] = []
            var queue: Deque<Int> = [docId]  // O(1) pop from front
            visited.insert(docId)

            while let current = queue.popFirst() {  // O(1) instead of O(n)
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

        return groups
    }

    /// Convert component groups to CloneGroups.
    private func convertToCloneGroups(
        _ groups: [[Int]],
        documentInfo: [Int: DocumentLocationInfo],
        pairs: [ClonePairInfo],
    ) -> [CloneGroup] {
        groups.compactMap { component -> CloneGroup? in
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
            let avgSimilarity =
                groupPairs.isEmpty
                ? minimumSimilarity : groupPairs.reduce(0.0) { $0 + $1.similarity } / Double(groupPairs.count)

            // Generate fingerprint from document IDs
            let fingerprint = component.sorted().map(String.init).joined(separator: "-")

            return CloneGroup(
                type: .semantic,  // Type-3 clones are reported as semantic
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
