//  HNSWIndexTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("HNSW Index Tests")
struct HNSWIndexTests {
    private func bruteForceTopK(
        query: [Float],
        vectors: [(id: Int, vector: [Float])],
        k: Int
    ) -> [Int] {
        var normalizedQuery = query
        HNSWVectorMath.normalize(&normalizedQuery)

        let scored = vectors.map { entry -> (Int, Float) in
            var normalized = entry.vector
            HNSWVectorMath.normalize(&normalized)
            let distance = HNSWVectorMath.cosineDistanceNormalized(normalizedQuery, normalized)
            return (entry.id, distance)
        }

        return scored.sorted { $0.1 < $1.1 }.prefix(k).map(\.0)
    }

    private func makeRandomVector(dim: Int, seed: inout UInt64) -> [Float] {
        var vector = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let raw = Float(Double(seed) / Double(UInt64.max))
            vector[i] = raw * 2 - 1
        }
        return vector
    }

    @Test("Exact vector query returns the inserted point as nearest neighbor")
    func exactVectorQueryReturnsSelf() {
        var index = HNSWIndex<Int>(dimension: 8)
        let vectors: [[Float]] = [
            [1, 0, 0, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0, 0, 0],
            [0.5, 0.5, 0, 0, 0, 0, 0, 0],
        ]
        for (i, vector) in vectors.enumerated() {
            index.insert(id: i, vector: vector)
        }

        for (i, vector) in vectors.enumerated() {
            let results = index.search(query: vector, k: 1)
            #expect(results.count == 1, "expected one result for query \(i)")
            #expect(results.first?.id == i, "query \(i) should return itself")
            if let first = results.first {
                #expect(first.similarity > 0.99, "similarity should be ~1.0, got \(first.similarity)")
            }
        }
    }

    @Test("HNSW top-k recovers brute-force baseline on synthetic dataset")
    func topKMatchesBruteForce() {
        let dimension = 16
        let count = 50
        let k = 5

        var index = HNSWIndex<Int>(
            dimension: dimension,
            configuration: HNSWConfiguration(
                m: 8,
                efConstruction: 100,
                efSearch: 100,
                seed: 0xCAFE_BABE_DEAD_BEEF
            )
        )

        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        var vectors: [(id: Int, vector: [Float])] = []
        for i in 0..<count {
            let vector = makeRandomVector(dim: dimension, seed: &seed)
            vectors.append((i, vector))
            index.insert(id: i, vector: vector)
        }

        var totalRecall = 0.0
        for query in vectors {
            let bruteIds = Set(bruteForceTopK(query: query.vector, vectors: vectors, k: k))
            let hnswIds = Set(index.search(query: query.vector, k: k).map(\.id))
            let intersection = Double(bruteIds.intersection(hnswIds).count)
            totalRecall += intersection / Double(k)
        }
        let avgRecall = totalRecall / Double(vectors.count)
        #expect(avgRecall >= 0.6, "average recall@\(k) was \(avgRecall)")
    }

    @Test("Insertion normalizes non-unit-length vectors")
    func insertionNormalizesVectors() {
        var index = HNSWIndex<Int>(dimension: 4)
        index.insert(id: 1, vector: [1, 0, 0, 0])
        index.insert(id: 2, vector: [100, 0, 0, 0])

        let results = index.search(query: [1, 0, 0, 0], k: 2)
        #expect(results.count == 2)
        for result in results {
            #expect(result.similarity > 0.99, "expected similarity ~1, got \(result.similarity)")
        }
    }

    @Test("Empty index returns no results")
    func emptyIndexReturnsNoResults() {
        let index = HNSWIndex<Int>(dimension: 4)
        let results = index.search(query: [1, 0, 0, 0], k: 5)
        #expect(results.isEmpty)
    }

    @Test("Count reflects number of insertions")
    func countReflectsInsertions() {
        var index = HNSWIndex<String>(dimension: 4)
        #expect(index.count == 0)
        index.insert(id: "a", vector: [1, 0, 0, 0])
        #expect(index.count == 1)
        index.insert(id: "b", vector: [0, 1, 0, 0])
        index.insert(id: "c", vector: [0, 0, 1, 0])
        #expect(index.count == 3)
    }

    @Test("Deterministic with fixed seed across runs")
    func deterministicWithFixedSeed() {
        let config = HNSWConfiguration(m: 8, efConstruction: 50, efSearch: 50, seed: 42)

        var vectors: [[Float]] = []
        var seed: UInt64 = 0xABCD_1234
        for _ in 0..<20 {
            vectors.append(makeRandomVector(dim: 8, seed: &seed))
        }

        var indexA = HNSWIndex<Int>(dimension: 8, configuration: config)
        var indexB = HNSWIndex<Int>(dimension: 8, configuration: config)
        for (i, vector) in vectors.enumerated() {
            indexA.insert(id: i, vector: vector)
            indexB.insert(id: i, vector: vector)
        }

        let queryA = indexA.search(query: vectors[0], k: 5).map(\.id)
        let queryB = indexB.search(query: vectors[0], k: 5).map(\.id)
        #expect(queryA == queryB, "same seed should yield identical results")
    }
}
