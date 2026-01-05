//  ParallelCloneDetectionTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

// MARK: - Helper to create ShingledDocument

private func makeDocument(id: Int, file: String, startLine: Int, endLine: Int, tokenCount: Int, hashes: Set<UInt64>)
    -> ShingledDocument
{
    ShingledDocument(
        file: file,
        startLine: startLine,
        endLine: endLine,
        tokenCount: tokenCount,
        shingleHashes: hashes,
        shingles: [],
        id: id
    )
}

// MARK: - CloneSimilarityGraph Tests

@Suite("Clone Similarity Graph Tests")
struct CloneSimilarityGraphTests {
    @Test("Empty graph construction")
    func emptyGraph() {
        let graph = CloneSimilarityGraph(size: 10)

        #expect(graph.nodeCount == 10)
        #expect(graph.edgeCount == 0)
        #expect(graph.isEmpty)
    }

    @Test("Graph from pairs")
    func graphFromPairs() {
        // Create mock documents
        let doc1 = makeDocument(id: 0, file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 2, 3])
        let doc2 = makeDocument(id: 1, file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 2, 4])
        let doc3 = makeDocument(id: 2, file: "c.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 5, 6])

        let pairs = [
            ClonePairInfo(doc1: doc1, doc2: doc2, similarity: 0.8),
            ClonePairInfo(doc1: doc2, doc2: doc3, similarity: 0.6),
        ]

        let graph = CloneSimilarityGraph(pairs: pairs, maxDocId: 2)

        #expect(graph.nodeCount == 3)
        #expect(graph.edgeCount == 4)  // 2 pairs * 2 (undirected)
        #expect(!graph.isEmpty)

        // Check adjacency
        #expect(graph.adjacency[0].contains(1))
        #expect(graph.adjacency[1].contains(0))
        #expect(graph.adjacency[1].contains(2))
        #expect(graph.adjacency[2].contains(1))
    }

    @Test("Graph statistics")
    func graphStatistics() {
        let doc1 = makeDocument(id: 0, file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1])
        let doc2 = makeDocument(id: 1, file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1])

        let pairs = [ClonePairInfo(doc1: doc1, doc2: doc2, similarity: 0.8)]
        let graph = CloneSimilarityGraph(pairs: pairs, maxDocId: 1)

        let stats = graph.statistics()

        #expect(stats.nodeCount == 2)
        #expect(stats.edgeCount == 1)  // Undirected count
        #expect(stats.maxDegree == 1)
        #expect(stats.isolatedNodes == 0)
    }
}

// MARK: - ParallelMinHash Tests

@Suite("Parallel MinHash Generator Tests")
struct ParallelMinHashGeneratorTests {
    @Test("Empty documents")
    func emptyDocuments() async {
        let generator = ParallelMinHashGenerator(numHashes: 64)
        let signatures = await generator.computeSignatures(for: [])

        #expect(signatures.isEmpty)
    }

    @Test("Single document")
    func singleDocument() async {
        let generator = ParallelMinHashGenerator(numHashes: 64)
        let doc = makeDocument(
            id: 0, file: "test.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 2, 3, 4, 5])

        let signatures = await generator.computeSignatures(for: [doc])

        #expect(signatures.count == 1)
        #expect(signatures[0].documentId == 0)
        #expect(signatures[0].values.count == 64)
    }

    @Test("Multiple documents preserve order")
    func orderPreservation() async {
        let generator = ParallelMinHashGenerator(numHashes: 64, maxConcurrency: 4)

        let documents = (0..<20).map { i in
            makeDocument(
                id: i, file: "file\(i).swift", startLine: 1, endLine: 10, tokenCount: 50,
                hashes: Set((0..<10).map { UInt64($0 + i * 10) }))
        }

        let signatures = await generator.computeSignatures(for: documents)

        #expect(signatures.count == 20)

        // Verify order is preserved
        for (index, sig) in signatures.enumerated() {
            #expect(sig.documentId == index)
        }
    }

    @Test("Parallel matches sequential")
    func parallelMatchesSequential() async {
        let parallelGen = ParallelMinHashGenerator(numHashes: 64, seed: 42)
        let sequentialGen = MinHashGenerator(numHashes: 64, seed: 42)

        let documents = (0..<10).map { i in
            makeDocument(
                id: i, file: "file\(i).swift", startLine: 1, endLine: 10, tokenCount: 50,
                hashes: Set((0..<5).map { UInt64($0 + i) }))
        }

        let parallelSigs = await parallelGen.computeSignatures(for: documents)
        let sequentialSigs = sequentialGen.computeSignatures(for: documents)

        #expect(parallelSigs.count == sequentialSigs.count)

        for (pSig, sSig) in zip(parallelSigs, sequentialSigs) {
            #expect(pSig.documentId == sSig.documentId)
            #expect(pSig.values == sSig.values)
        }
    }
}

// MARK: - ParallelVerifier Tests

@Suite("Parallel Verifier Tests")
struct ParallelVerifierTests {
    @Test("Empty candidates")
    func emptyCandidates() async {
        let verifier = ParallelVerifier(minimumSimilarity: 0.5)
        let results = await verifier.verifyCandidatePairs([], documentMap: [:])

        #expect(results.isEmpty)
    }

    @Test("Single pair verification")
    func singlePairVerification() async {
        let verifier = ParallelVerifier(minimumSimilarity: 0.5)

        let doc1 = makeDocument(
            id: 0, file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 2, 3, 4, 5])
        // 3/7 = 0.43 similarity
        let doc2 = makeDocument(
            id: 1, file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 2, 3, 6, 7])

        let documentMap = [0: doc1, 1: doc2]
        let candidates: Set<DocumentPair> = [DocumentPair(id1: 0, id2: 1)]

        let results = await verifier.verifyCandidatePairs(candidates, documentMap: documentMap)

        // Below threshold, so no results
        #expect(results.isEmpty)
    }

    @Test("Pair above threshold")
    func pairAboveThreshold() async {
        let verifier = ParallelVerifier(minimumSimilarity: 0.5)

        let doc1 = makeDocument(
            id: 0, file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 2, 3, 4, 5])
        // 4/6 = 0.67 similarity
        let doc2 = makeDocument(
            id: 1, file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 2, 3, 4, 6])

        let documentMap = [0: doc1, 1: doc2]
        let candidates: Set<DocumentPair> = [DocumentPair(id1: 0, id2: 1)]

        let results = await verifier.verifyCandidatePairs(candidates, documentMap: documentMap)

        #expect(results.count == 1)
        #expect(results[0].similarity >= 0.5)
    }

    @Test("Overlapping documents filtered")
    func overlappingFiltered() async {
        let verifier = ParallelVerifier(minimumSimilarity: 0.5)

        // Same file, overlapping lines
        let doc1 = makeDocument(
            id: 0, file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1, 2, 3, 4, 5])
        // Overlaps with doc1
        let doc2 = makeDocument(
            id: 1, file: "a.swift", startLine: 5, endLine: 15, tokenCount: 50, hashes: [1, 2, 3, 4, 5])

        let documentMap = [0: doc1, 1: doc2]
        let candidates: Set<DocumentPair> = [DocumentPair(id1: 0, id2: 1)]

        let results = await verifier.verifyCandidatePairs(candidates, documentMap: documentMap)

        // Should be filtered out due to overlap
        #expect(results.isEmpty)
    }
}

// MARK: - ParallelConnectedComponents Tests

@Suite("Parallel Connected Components Tests")
struct ParallelConnectedComponentsTests {
    @Test("Empty graph")
    func emptyGraph() async {
        let graph = CloneSimilarityGraph(size: 0)
        let components = await ParallelConnectedComponents.findComponents(graph: graph)

        #expect(components.isEmpty)
    }

    @Test("Single edge component")
    func singleEdgeComponent() async {
        let doc1 = makeDocument(id: 0, file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1])
        let doc2 = makeDocument(id: 1, file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1])

        let pairs = [ClonePairInfo(doc1: doc1, doc2: doc2, similarity: 0.8)]
        let graph = CloneSimilarityGraph(pairs: pairs, maxDocId: 1)

        let components = await ParallelConnectedComponents.findComponents(graph: graph)

        #expect(components.count == 1)
        #expect(Set(components[0]) == Set([0, 1]))
    }

    @Test("Two separate components")
    func twoSeparateComponents() async {
        let doc0 = makeDocument(id: 0, file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1])
        let doc1 = makeDocument(id: 1, file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1])
        let doc2 = makeDocument(id: 2, file: "c.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [2])
        let doc3 = makeDocument(id: 3, file: "d.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [2])

        let pairs = [
            ClonePairInfo(doc1: doc0, doc2: doc1, similarity: 0.8),
            ClonePairInfo(doc1: doc2, doc2: doc3, similarity: 0.8),
        ]
        let graph = CloneSimilarityGraph(pairs: pairs, maxDocId: 3)

        let components = await ParallelConnectedComponents.findComponents(graph: graph)

        #expect(components.count == 2)

        let componentSets = components.map { Set($0) }
        #expect(componentSets.contains(Set([0, 1])))
        #expect(componentSets.contains(Set([2, 3])))
    }

    @Test("Sequential fallback for small graphs")
    func sequentialFallback() async {
        // Small graph should use sequential algorithm
        let config = ParallelConnectedComponents.Configuration(minParallelSize: 1000)

        let doc0 = makeDocument(id: 0, file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1])
        let doc1 = makeDocument(id: 1, file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, hashes: [1])

        let pairs = [ClonePairInfo(doc1: doc0, doc2: doc1, similarity: 0.8)]
        let graph = CloneSimilarityGraph(pairs: pairs, maxDocId: 1)

        let (components, stats) = await ParallelConnectedComponents.findComponentsWithStats(
            graph: graph,
            configuration: config
        )

        #expect(components.count == 1)
        #expect(!stats.usedParallel)  // Should use sequential
    }
}

// MARK: - Parallel vs Sequential Equivalence Tests

@Suite("Parallel vs Sequential Equivalence Tests")
struct ParallelSequentialEquivalenceTests {
    @Test("MinHashCloneDetector parallel matches sequential")
    func detectorEquivalence() async {
        // Create test sequences with known similar content
        let tokens1: [TokenInfo] = (0..<30).map { i in
            TokenInfo(kind: .identifier, text: "token\(i % 8)", line: i / 8 + 1, column: 0)
        }
        let tokens2: [TokenInfo] = (0..<30).map { i in
            TokenInfo(kind: .identifier, text: "token\(i % 8)", line: i / 8 + 1, column: 0)
        }
        let tokens3: [TokenInfo] = (0..<30).map { i in
            TokenInfo(kind: .identifier, text: "different\(i)", line: i / 8 + 1, column: 0)
        }

        let seq1 = TokenSequence(file: "file1.swift", tokens: tokens1, sourceLines: [""])
        let seq2 = TokenSequence(file: "file2.swift", tokens: tokens2, sourceLines: [""])
        let seq3 = TokenSequence(file: "file3.swift", tokens: tokens3, sourceLines: [""])
        let sequences = [seq1, seq2, seq3]

        // Sequential detection
        let sequentialDetector = MinHashCloneDetector(
            minimumTokens: 10,
            shingleSize: 3,
            numHashes: 64,
            minimumSimilarity: 0.4,
            parallelConfig: .sequential
        )
        let sequentialClones = sequentialDetector.detect(in: sequences)

        // Parallel detection
        let parallelDetector = MinHashCloneDetector(
            minimumTokens: 10,
            shingleSize: 3,
            numHashes: 64,
            minimumSimilarity: 0.4,
            parallelConfig: .default
        )
        let parallelClones = await parallelDetector.detectParallel(in: sequences)

        // Both should find same number of clone groups
        #expect(sequentialClones.count == parallelClones.count)

        // All clones should have valid similarity
        #expect(sequentialClones.allSatisfy { $0.similarity >= 0.4 })
        #expect(parallelClones.allSatisfy { $0.similarity >= 0.4 })
    }

    @Test("ParallelCloneConfiguration defaults")
    func configurationDefaults() {
        let config = ParallelCloneConfiguration.default

        #expect(config.enabled)
        #expect(config.minParallelDocuments == 50)
        #expect(config.minParallelPairs == 100)
        #expect(config.maxConcurrency > 0)
    }

    @Test("ParallelCloneConfiguration sequential")
    func configurationSequential() {
        let config = ParallelCloneConfiguration.sequential

        #expect(!config.enabled)
    }
}
