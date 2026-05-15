//  EmbeddingCloneDiscovery.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - EmbeddingSnippet

/// A snippet of source code paired with its location, ready to be embedded.
///
/// The discovery driver embeds each snippet via a `SemanticEmbeddingProvider`,
/// inserts the resulting vector into an `HNSWIndex`, then queries the index
/// to recover near-duplicate groups MinHash may have missed.
public struct EmbeddingSnippet: Sendable, Hashable {
    public init(
        file: String,
        startLine: Int,
        endLine: Int,
        tokenCount: Int,
        code: String
    ) {
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.tokenCount = tokenCount
        self.code = code
    }

    public let file: String
    public let startLine: Int
    public let endLine: Int
    public let tokenCount: Int
    public let code: String
}

// MARK: - EmbeddingCloneDiscovery

/// Builds an approximate-nearest-neighbor index over snippet embeddings and
/// surfaces clone groups via top-k queries.
///
/// 1. Embed every snippet via `provider`.
/// 2. Insert into `HNSWIndex<Int>` keyed by snippet index.
/// 3. For each snippet, query top-k neighbors; pairs whose cosine similarity
///    is at least `similarityThreshold` form edges in a similarity graph.
/// 4. Compute connected components (union-find) to get clone groups.
/// 5. Drop singleton components; emit a `CloneGroup` per component with
///    `type: .semantic` and `similarity` = average pairwise cosine.
///
/// Brute force is O(n²) on the number of snippets; HNSW averages O(n log n).
/// For 10k snippets at 768 dim the brute force pass alone would be ~10⁸ inner
/// products. HNSW pays a one-time build cost (~n log n) and supports fast
/// queries afterwards.
public struct EmbeddingCloneDiscovery: Sendable {
    public init(
        hnswConfiguration: HNSWConfiguration = .default
    ) {
        self.hnswConfiguration = hnswConfiguration
    }

    public let hnswConfiguration: HNSWConfiguration

    /// Discover clone groups via embedding-based ANN search.
    ///
    /// - Parameters:
    ///   - snippets: Snippets to embed and index.
    ///   - provider: Embedding provider (Core ML, sentence-transformer, etc.).
    ///   - k: Top-k neighbors per query. Larger = better recall, slower.
    ///   - similarityThreshold: Minimum cosine similarity to keep a pair.
    /// - Returns: `[CloneGroup]` with `type == .semantic`. Empty if no pairs
    ///   above threshold or fewer than 2 snippets supplied.
    public func discover(
        snippets: [EmbeddingSnippet],
        provider: SemanticEmbeddingProvider,
        k: Int = 10,
        similarityThreshold: Double = 0.92
    ) async throws -> [CloneGroup] {
        guard snippets.count >= 2, k > 0 else { return [] }

        let vectors = try await provider.embed(snippets: snippets.map(\.code))
        guard vectors.count == snippets.count else { return [] }

        var index = HNSWIndex<Int>(
            dimension: provider.embeddingDimension,
            configuration: hnswConfiguration
        )
        for (i, vector) in vectors.enumerated() {
            index.insert(id: i, vector: vector)
        }

        var pairs: [(Int, Int, Float)] = []
        var seenPair = Set<UInt64>()

        for i in 0..<snippets.count {
            let results = index.search(query: vectors[i], k: k + 1)
            for result in results {
                let j = result.id
                if j == i { continue }
                if shouldSkipPair(snippets[i], snippets[j]) { continue }
                if Double(result.similarity) < similarityThreshold { continue }

                let a = min(i, j)
                let b = max(i, j)
                let key = (UInt64(a) << 32) | UInt64(b)
                if seenPair.insert(key).inserted {
                    pairs.append((a, b, result.similarity))
                }
            }
        }

        guard !pairs.isEmpty else { return [] }

        var uf = UnionFind(count: snippets.count)
        for (a, b, _) in pairs { uf.union(a, b) }

        var pairsByRoot: [Int: [(Int, Int, Float)]] = [:]
        var memberSet: [Int: Set<Int>] = [:]

        for (a, b, sim) in pairs {
            let root = uf.find(a)
            memberSet[root, default: []].insert(a)
            memberSet[root, default: []].insert(b)
            pairsByRoot[root, default: []].append((a, b, sim))
        }

        var groups: [CloneGroup] = []
        groups.reserveCapacity(memberSet.count)

        for (root, members) in memberSet where members.count >= 2 {
            let indices = members.sorted()
            let groupPairs = pairsByRoot[root] ?? []
            let avgSimilarity =
                groupPairs.isEmpty
                ? similarityThreshold
                : Double(groupPairs.reduce(Float(0)) { $0 + $1.2 }) / Double(groupPairs.count)

            let clones = indices.map { idx -> Clone in
                let snippet = snippets[idx]
                return Clone(
                    file: snippet.file,
                    startLine: snippet.startLine,
                    endLine: snippet.endLine,
                    tokenCount: snippet.tokenCount,
                    codeSnippet: snippet.code,
                )
            }

            let fingerprint = "embedding-" + indices.map(String.init).joined(separator: "-")
            groups.append(
                CloneGroup(
                    type: .semantic,
                    clones: clones,
                    similarity: avgSimilarity,
                    fingerprint: fingerprint,
                )
            )
        }

        return groups
    }

    /// Filter out pairs in the same file with overlapping line ranges.
    private func shouldSkipPair(_ a: EmbeddingSnippet, _ b: EmbeddingSnippet) -> Bool {
        guard a.file == b.file else { return false }
        return !(a.endLine < b.startLine || b.endLine < a.startLine)
    }
}

// MARK: - UnionFind

/// Simple union-find with path compression for grouping clone pairs.
struct UnionFind: Sendable {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = [Int](repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x])
        }
        return parent[x]
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }

        if rank[rootA] < rank[rootB] {
            parent[rootA] = rootB
        } else if rank[rootA] > rank[rootB] {
            parent[rootB] = rootA
        } else {
            parent[rootB] = rootA
            rank[rootA] += 1
        }
    }
}
