//  CloneSimilarityGraph.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - CloneSimilarityGraph

/// Dense graph representation for clone similarity.
///
/// Leverages the fact that `ShingledDocument.id` values are contiguous
/// integers starting from 0, so no ID remapping is needed.
///
/// ## Design
///
/// This mirrors `DenseGraph` from ParallelBFS:
/// - Adjacency stored as `[[Int]]` for cache efficiency
/// - No hashing overhead (direct array access)
/// - Suitable for AtomicBitmap-based visited tracking
///
/// ## Thread Safety
///
/// - Fully immutable after construction
/// - Safe for concurrent read access
public struct CloneSimilarityGraph: Sendable {
    // MARK: Lifecycle

    /// Create from verified clone pairs.
    ///
    /// - Parameters:
    ///   - pairs: Verified clone pairs.
    ///   - maxDocId: Maximum document ID (determines array size).
    public init(pairs: [ClonePairInfo], maxDocId: Int) {
        var adj: [[Int]] = Array(repeating: [], count: maxDocId + 1)
        var edges = 0

        for pair in pairs {
            adj[pair.doc1.id].append(pair.doc2.id)
            adj[pair.doc2.id].append(pair.doc1.id)
            edges += 2  // Undirected = 2 directed edges per pair
        }

        self.adjacency = adj
        self.edgeCount = edges
    }

    /// Create from adjacency dictionary.
    ///
    /// Converts `[Int: Set<Int>]` adjacency to dense `[[Int]]` representation.
    ///
    /// - Parameters:
    ///   - adjacencyDict: Dictionary-based adjacency list.
    ///   - maxDocId: Maximum document ID.
    public init(adjacencyDict: [Int: Set<Int>], maxDocId: Int) {
        var adj: [[Int]] = Array(repeating: [], count: maxDocId + 1)
        var edges = 0

        for (node, neighbors) in adjacencyDict where node <= maxDocId {
            adj[node] = Array(neighbors.filter { $0 <= maxDocId })
            edges += adj[node].count
        }

        self.adjacency = adj
        self.edgeCount = edges
    }

    /// Create an empty graph.
    ///
    /// - Parameter size: Number of nodes.
    public init(size: Int) {
        self.adjacency = Array(repeating: [], count: size)
        self.edgeCount = 0
    }

    // MARK: Public

    /// Adjacency list: adjacency[docId] = [neighborDocId, ...]
    public let adjacency: [[Int]]

    /// Total edge count (each undirected edge counts as 2).
    public let edgeCount: Int

    /// Total node count.
    public var nodeCount: Int { adjacency.count }

    /// Check if the graph is empty.
    public var isEmpty: Bool { adjacency.isEmpty || edgeCount == 0 }

    /// Get the degree (number of neighbors) for a node.
    ///
    /// - Parameter node: Node index.
    /// - Returns: Number of neighbors.
    public func degree(of node: Int) -> Int {
        guard node >= 0, node < adjacency.count else { return 0 }
        return adjacency[node].count
    }

    /// Get all nodes with at least one edge.
    ///
    /// - Returns: Array of node indices with edges.
    public func nodesWithEdges() -> [Int] {
        adjacency.enumerated().compactMap { index, neighbors in
            neighbors.isEmpty ? nil : index
        }
    }

    /// Compute total out-edges from a set of nodes.
    ///
    /// - Parameter nodes: Array of node indices.
    /// - Returns: Sum of degrees.
    public func totalOutEdges(from nodes: [Int]) -> Int {
        nodes.reduce(0) { total, node in
            guard node >= 0, node < adjacency.count else { return total }
            return total + adjacency[node].count
        }
    }
}

// MARK: - Graph Statistics

extension CloneSimilarityGraph {
    /// Statistics about the graph structure.
    public struct Statistics: Sendable {
        /// Number of nodes.
        public let nodeCount: Int

        /// Number of edges (undirected count).
        public let edgeCount: Int

        /// Average degree.
        public let averageDegree: Double

        /// Maximum degree.
        public let maxDegree: Int

        /// Number of isolated nodes (no edges).
        public let isolatedNodes: Int
    }

    /// Compute graph statistics.
    public func statistics() -> Statistics {
        var maxDegree = 0
        var isolatedCount = 0
        var totalDegree = 0

        for neighbors in adjacency {
            let degree = neighbors.count
            totalDegree += degree
            maxDegree = max(maxDegree, degree)
            if degree == 0 {
                isolatedCount += 1
            }
        }

        let avgDegree = nodeCount > 0 ? Double(totalDegree) / Double(nodeCount) : 0

        return Statistics(
            nodeCount: nodeCount,
            edgeCount: edgeCount / 2,  // Convert to undirected count
            averageDegree: avgDegree,
            maxDegree: maxDegree,
            isolatedNodes: isolatedCount
        )
    }
}
