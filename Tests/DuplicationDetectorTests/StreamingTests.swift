//
//  StreamingTests.swift
//  SwiftStaticAnalysis
//
//  Tests for streaming components using swift-async-algorithms.
//

import Testing

@testable import DuplicationDetector
@testable import SwiftStaticAnalysisCore

// MARK: - Streaming LSH Tests

@Suite("Streaming LSH Tests")
struct StreamingLSHTests {
    @Test("Streaming candidate pairs produces same results as non-streaming")
    func streamingEquivalence() async {
        // Create test signatures
        let signatures = createTestSignatures(count: 20)

        // Build index
        var index = LSHIndex(bands: 4, rows: 2)
        index.insert(signatures)

        // Get results via non-streaming
        let nonStreamingPairs = index.findCandidatePairs()

        // Get results via streaming
        var streamingPairs = Set<DocumentPair>()
        for await pair in index.findCandidatePairsStreaming() {
            streamingPairs.insert(pair)
        }

        // Should be identical
        #expect(streamingPairs == nonStreamingPairs)
    }

    @Test("findCandidatePairs(mode:) respects parallel mode")
    func parallelModeIntegration() async {
        let signatures = createTestSignatures(count: 15)

        var index = LSHIndex(bands: 4, rows: 2)
        index.insert(signatures)

        // All modes should produce identical results
        let nonePairs = await index.findCandidatePairs(mode: .none)
        let safePairs = await index.findCandidatePairs(mode: .safe)
        let maxPairs = await index.findCandidatePairs(mode: .maximum)

        #expect(nonePairs == safePairs)
        #expect(safePairs == maxPairs)
    }

    @Test("Streaming deduplicates pairs across bands")
    func streamingDeduplication() async {
        // Create signatures that will collide in multiple bands
        let sig1 = MinHashSignature(values: [1, 2, 3, 4, 1, 2, 3, 4], documentId: 1)
        let sig2 = MinHashSignature(values: [1, 2, 3, 4, 1, 2, 3, 4], documentId: 2)

        var index = LSHIndex(bands: 2, rows: 4)
        index.insert([sig1, sig2])

        // Count pairs from streaming
        var pairs: [DocumentPair] = []
        for await pair in index.findCandidatePairsStreaming() {
            pairs.append(pair)
        }

        // Should only have one pair (deduplicated)
        #expect(pairs.count == 1)
    }

    // MARK: - Helpers

    private func createTestSignatures(count: Int) -> [MinHashSignature] {
        (0..<count).map { id in
            // Create semi-random signatures that will have some collisions
            let values = (0..<8).map { i -> UInt64 in
                UInt64((id * 17 + i * 13) % 100)
            }
            return MinHashSignature(values: values, documentId: id)
        }
    }
}

// MARK: - Streaming Verifier Tests

@Suite("Streaming Verifier Tests")
struct StreamingVerifierTests {
    @Test("StreamingVerifier produces progress updates")
    func progressUpdates() async {
        let (candidates, documentMap) = createTestData(pairCount: 50)

        let verifier = StreamingVerifier(
            minimumSimilarity: 0.0,  // Accept all
            batchSize: 10
        )

        var progressUpdates: [VerificationProgress] = []
        for await progress in verifier.verifyStreaming(candidates, documentMap: documentMap) {
            progressUpdates.append(progress)
        }

        // Should have multiple progress updates
        #expect(progressUpdates.count >= 1)

        // Progress should increase
        if progressUpdates.count > 1 {
            #expect(progressUpdates.last!.processed >= progressUpdates.first!.processed)
        }

        // Final progress should be 100%
        if let last = progressUpdates.last {
            #expect(last.progress == 1.0)
            #expect(last.processed == last.total)
        }
    }

    @Test("StreamingVerifier collectResults matches non-streaming")
    func collectResultsEquivalence() async {
        let (candidates, documentMap) = createTestData(pairCount: 30)

        let batchVerifier = BatchVerifier(minimumSimilarity: 0.3, batchSize: 10)
        let streamingVerifier = StreamingVerifier(minimumSimilarity: 0.3, batchSize: 10)

        let batchResults = await batchVerifier.verifyCandidatePairs(
            candidates,
            documentMap: documentMap
        )
        let streamingResults = await streamingVerifier.collectResults(
            candidates,
            documentMap: documentMap
        )

        // Sort for comparison (order may differ)
        let sortedBatch = batchResults.sorted { $0.similarity > $1.similarity }
        let sortedStreaming = streamingResults.sorted { $0.similarity > $1.similarity }

        #expect(sortedBatch.count == sortedStreaming.count)
    }

    @Test("streamResults yields individual pairs")
    func streamResultsYieldsPairs() async {
        let (candidates, documentMap) = createTestData(pairCount: 20)

        let verifier = StreamingVerifier(minimumSimilarity: 0.0, batchSize: 5)

        var results: [ClonePairInfo] = []
        for await pair in verifier.streamResults(candidates, documentMap: documentMap) {
            results.append(pair)
        }

        // Should have results (all pairs accepted with threshold 0)
        #expect(!results.isEmpty)
    }

    @Test("ParallelVerifier.forMode creates correct configurations")
    func parallelVerifierModes() {
        let noneVerifier = ParallelVerifier.forMode(.none)
        #expect(noneVerifier.maxConcurrency == 1)

        let safeVerifier = ParallelVerifier.forMode(.safe)
        #expect(safeVerifier.maxConcurrency >= 1)

        let maxVerifier = ParallelVerifier.forMode(.maximum)
        #expect(maxVerifier.maxConcurrency > safeVerifier.maxConcurrency)
        #expect(maxVerifier.minParallelPairs < safeVerifier.minParallelPairs)
    }

    // MARK: - Helpers

    private func createTestData(pairCount: Int) -> (Set<DocumentPair>, [Int: ShingledDocument]) {
        var candidates = Set<DocumentPair>()
        var documentMap: [Int: ShingledDocument] = [:]

        for i in 0..<(pairCount * 2) {
            let shingleHashes = Set((0..<10).map { UInt64($0 + i * 5) })
            documentMap[i] = ShingledDocument(
                file: "test\(i).swift",
                startLine: i * 10,
                endLine: i * 10 + 5,
                tokenCount: 20,
                shingleHashes: shingleHashes,
                shingles: [],  // Empty for test purposes
                id: i
            )
        }

        for i in stride(from: 0, to: pairCount * 2, by: 2) {
            candidates.insert(DocumentPair(id1: i, id2: i + 1))
        }

        return (candidates, documentMap)
    }
}

// MARK: - VerificationProgress Tests

@Suite("VerificationProgress Tests")
struct VerificationProgressTests {
    @Test("Progress percentage calculates correctly")
    func progressPercentage() {
        let progress1 = VerificationProgress(processed: 50, total: 100, batchResults: [])
        #expect(progress1.progress == 0.5)

        let progress2 = VerificationProgress(processed: 100, total: 100, batchResults: [])
        #expect(progress2.progress == 1.0)

        let progress3 = VerificationProgress(processed: 0, total: 100, batchResults: [])
        #expect(progress3.progress == 0.0)
    }

    @Test("Progress handles zero total")
    func progressZeroTotal() {
        let progress = VerificationProgress(processed: 0, total: 0, batchResults: [])
        #expect(progress.progress == 1.0)  // Edge case: 0/0 = 100%
    }
}
