//  EmbeddingCloneDiscoveryTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("Embedding Clone Discovery Tests")
struct EmbeddingCloneDiscoveryTests {
    /// Lookup-table embedding provider for deterministic tests.
    struct StubEmbeddingProvider: SemanticEmbeddingProvider {
        let embeddingDimension: Int
        let lookup: [String: [Float]]

        func embed(snippet: String) async throws -> [Float] {
            if let vector = lookup[snippet] { return vector }
            return [Float](repeating: 0, count: embeddingDimension)
        }
    }

    private func makeSnippet(
        file: String,
        startLine: Int,
        endLine: Int,
        code: String
    ) -> EmbeddingSnippet {
        EmbeddingSnippet(
            file: file,
            startLine: startLine,
            endLine: endLine,
            tokenCount: 10,
            code: code
        )
    }

    @Test("Identical-embedding snippets are grouped together")
    func identicalEmbeddingsGroup() async throws {
        let dimension = 8
        let sharedVector: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]

        let snippets = [
            makeSnippet(file: "a.swift", startLine: 1, endLine: 10, code: "alpha"),
            makeSnippet(file: "b.swift", startLine: 1, endLine: 10, code: "beta"),
            makeSnippet(file: "c.swift", startLine: 1, endLine: 10, code: "gamma"),
        ]

        let provider = StubEmbeddingProvider(
            embeddingDimension: dimension,
            lookup: [
                "alpha": sharedVector,
                "beta": sharedVector,
                "gamma": sharedVector,
            ]
        )

        let discovery = EmbeddingCloneDiscovery()
        let groups = try await discovery.discover(
            snippets: snippets,
            provider: provider,
            k: 3,
            similarityThreshold: 0.9
        )

        #expect(groups.count == 1, "expected one merged clone group")
        if let first = groups.first {
            #expect(first.type == .semantic)
            #expect(first.clones.count == 3)
            #expect(first.similarity >= 0.9)
            let files = Set(first.clones.map(\.file))
            #expect(files == Set(["a.swift", "b.swift", "c.swift"]))
        }
    }

    @Test("Below-threshold pairs are not grouped")
    func belowThresholdNotGrouped() async throws {
        let dimension = 4
        let snippets = [
            makeSnippet(file: "a.swift", startLine: 1, endLine: 5, code: "x"),
            makeSnippet(file: "b.swift", startLine: 1, endLine: 5, code: "y"),
            makeSnippet(file: "c.swift", startLine: 1, endLine: 5, code: "z"),
        ]
        let provider = StubEmbeddingProvider(
            embeddingDimension: dimension,
            lookup: [
                "x": [1, 0, 0, 0],
                "y": [0, 1, 0, 0],
                "z": [0, 0, 1, 0],
            ]
        )

        let discovery = EmbeddingCloneDiscovery()
        let groups = try await discovery.discover(
            snippets: snippets,
            provider: provider,
            k: 3,
            similarityThreshold: 0.5
        )

        #expect(groups.isEmpty, "orthogonal vectors should yield no groups")
    }

    @Test("Same-file overlapping snippets are excluded from pairs")
    func sameFileOverlapExcluded() async throws {
        let dimension = 4
        let sharedVector: [Float] = [1, 0, 0, 0]

        let snippets = [
            makeSnippet(file: "same.swift", startLine: 1, endLine: 10, code: "p"),
            makeSnippet(file: "same.swift", startLine: 5, endLine: 15, code: "q"),
        ]
        let provider = StubEmbeddingProvider(
            embeddingDimension: dimension,
            lookup: ["p": sharedVector, "q": sharedVector]
        )

        let discovery = EmbeddingCloneDiscovery()
        let groups = try await discovery.discover(
            snippets: snippets,
            provider: provider,
            k: 2,
            similarityThreshold: 0.9
        )

        #expect(groups.isEmpty, "same-file overlapping snippets must not pair")
    }

    @Test("Two clusters of identical snippets yield two clone groups")
    func twoClustersYieldTwoGroups() async throws {
        let dimension = 4
        let clusterA: [Float] = [1, 0, 0, 0]
        let clusterB: [Float] = [0, 1, 0, 0]

        let snippets = [
            makeSnippet(file: "a1.swift", startLine: 1, endLine: 5, code: "a1"),
            makeSnippet(file: "a2.swift", startLine: 1, endLine: 5, code: "a2"),
            makeSnippet(file: "b1.swift", startLine: 1, endLine: 5, code: "b1"),
            makeSnippet(file: "b2.swift", startLine: 1, endLine: 5, code: "b2"),
        ]
        let provider = StubEmbeddingProvider(
            embeddingDimension: dimension,
            lookup: [
                "a1": clusterA,
                "a2": clusterA,
                "b1": clusterB,
                "b2": clusterB,
            ]
        )

        let discovery = EmbeddingCloneDiscovery()
        let groups = try await discovery.discover(
            snippets: snippets,
            provider: provider,
            k: 4,
            similarityThreshold: 0.9
        )

        #expect(groups.count == 2, "expected two distinct clone groups, got \(groups.count)")
        for group in groups {
            #expect(group.clones.count == 2)
        }
    }

    @Test("Empty input returns no groups")
    func emptyInputReturnsNoGroups() async throws {
        let provider = StubEmbeddingProvider(embeddingDimension: 4, lookup: [:])
        let discovery = EmbeddingCloneDiscovery()

        let empty = try await discovery.discover(
            snippets: [],
            provider: provider,
            k: 5,
            similarityThreshold: 0.9
        )
        #expect(empty.isEmpty)

        let single = try await discovery.discover(
            snippets: [makeSnippet(file: "x.swift", startLine: 1, endLine: 5, code: "z")],
            provider: provider,
            k: 5,
            similarityThreshold: 0.9
        )
        #expect(single.isEmpty)
    }

    @Test("DeterministicEmbeddingProvider produces stable vectors")
    func deterministicProviderStability() async throws {
        let provider = DeterministicEmbeddingProvider(dimension: 32, ngramSize: 3)
        let snippet = "func compute() -> Int { return 42 }"

        let v1 = try await provider.embed(snippet: snippet)
        let v2 = try await provider.embed(snippet: snippet)

        #expect(v1.count == 32)
        #expect(v1 == v2, "embeddings must be deterministic")
    }
}
