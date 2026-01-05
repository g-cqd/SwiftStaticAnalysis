//
//  DenseGraph.swift
//  SwiftStaticAnalysis
//
//  Dense graph representation optimized for parallel BFS.
//  Converts string-based node IDs to integers for O(1) array access.
//

import Foundation

// MARK: - DenseGraph

/// Dense graph representation optimized for parallel BFS.
///
/// Converts string-based node IDs to contiguous integers (0..<nodeCount)
/// for cache-efficient array access during traversal.
///
/// ## Performance Benefits
///
/// - **Cache Locality**: Contiguous integer indices enable sequential memory access
/// - **O(1) Lookups**: Array indexing vs. dictionary hashing
/// - **Bitmap Compatibility**: Integer indices map directly to bitmap positions
///
/// ## Memory Layout
///
/// ```
/// adjacency[i] = [j1, j2, ...] where edges exist from node i to nodes j1, j2, ...
/// reverseAdjacency[j] = [i1, i2, ...] where edges exist from nodes i1, i2, ... to j
/// ```
///
public struct DenseGraph: Sendable {
    // MARK: Lifecycle

    /// Create a dense graph from node IDs, edges, and roots.
    ///
    /// - Parameters:
    ///   - nodeIds: All unique node identifiers
    ///   - edges: Edges as (from, to) pairs using original string IDs
    ///   - rootIds: Root node identifiers
    public init(
        nodeIds: [String],
        edges: [(from: String, to: String)],
        rootIds: Set<String>
    ) {
        // Build bidirectional mapping
        var nodeToIndex: [String: Int] = [:]
        nodeToIndex.reserveCapacity(nodeIds.count)
        for (index, nodeId) in nodeIds.enumerated() {
            nodeToIndex[nodeId] = index
        }

        self.nodeToIndex = nodeToIndex
        self.indexToNode = nodeIds

        // Build adjacency lists
        var adjacency: [[Int]] = Array(repeating: [], count: nodeIds.count)
        var reverseAdjacency: [[Int]] = Array(repeating: [], count: nodeIds.count)
        var validEdgeCount = 0

        for (from, to) in edges {
            guard let fromIndex = nodeToIndex[from],
                let toIndex = nodeToIndex[to]
            else {
                continue  // Skip edges with unknown nodes
            }

            adjacency[fromIndex].append(toIndex)
            reverseAdjacency[toIndex].append(fromIndex)
            validEdgeCount += 1
        }

        self.adjacency = adjacency
        self.reverseAdjacency = reverseAdjacency
        self.edgeCount = validEdgeCount

        // Map root IDs to indices
        self.roots = rootIds.compactMap { nodeToIndex[$0] }

        // Precompute degree information for direction-optimizing BFS
        self.outDegrees = adjacency.map(\.count)
        self.inDegrees = reverseAdjacency.map(\.count)
    }

    // MARK: Public

    /// Map from original node ID to dense integer index.
    public let nodeToIndex: [String: Int]

    /// Map from dense index back to original node ID.
    public let indexToNode: [String]

    /// Adjacency list using dense indices.
    /// `adjacency[from]` contains all nodes reachable from `from`.
    public let adjacency: [[Int]]

    /// Reverse adjacency for bottom-up BFS.
    /// `reverseAdjacency[to]` contains all nodes with edges to `to`.
    public let reverseAdjacency: [[Int]]

    /// Root node indices.
    public let roots: [Int]

    /// Total number of edges.
    public let edgeCount: Int

    /// Out-degree for each node (number of outgoing edges).
    public let outDegrees: [Int]

    /// In-degree for each node (number of incoming edges).
    public let inDegrees: [Int]

    /// Total number of nodes.
    public var nodeCount: Int { indexToNode.count }

    /// Check if the graph is empty.
    public var isEmpty: Bool { nodeCount == 0 }

    /// Get neighbors of a node (outgoing edges).
    @inline(__always)
    public func neighbors(of node: Int) -> [Int] {
        adjacency[node]
    }

    /// Get predecessors of a node (incoming edges).
    @inline(__always)
    public func predecessors(of node: Int) -> [Int] {
        reverseAdjacency[node]
    }

    /// Convert dense indices back to original node IDs.
    public func toNodeIds(_ indices: Set<Int>) -> Set<String> {
        Set(indices.map { indexToNode[$0] })
    }

    /// Convert dense indices back to original node IDs (array version).
    public func toNodeIds(_ indices: [Int]) -> [String] {
        indices.map { indexToNode[$0] }
    }

    /// Calculate total edges from a set of nodes (for direction-optimizing heuristics).
    public func totalOutEdges(from nodes: [Int]) -> Int {
        nodes.reduce(0) { $0 + outDegrees[$1] }
    }

    /// Calculate remaining unvisited edges (approximate).
    public func remainingEdges(visited: AtomicBitmap) -> Int {
        var count = 0
        for i in 0..<nodeCount where !visited.test(i) {
            count += outDegrees[i]
        }
        return count
    }
}

// MARK: - DenseGraph + Statistics

extension DenseGraph {
    /// Graph statistics for debugging and analysis.
    public struct Statistics: Sendable {
        public let nodeCount: Int
        public let edgeCount: Int
        public let rootCount: Int
        public let avgOutDegree: Double
        public let maxOutDegree: Int
        public let avgInDegree: Double
        public let maxInDegree: Int
    }

    /// Compute graph statistics.
    public var statistics: Statistics {
        let maxOut = outDegrees.max() ?? 0
        let maxIn = inDegrees.max() ?? 0
        let avgOut = nodeCount > 0 ? Double(edgeCount) / Double(nodeCount) : 0
        let avgIn = avgOut  // Same for directed graphs

        return Statistics(
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            rootCount: roots.count,
            avgOutDegree: avgOut,
            maxOutDegree: maxOut,
            avgInDegree: avgIn,
            maxInDegree: maxIn
        )
    }
}

// MARK: - DenseGraph + Sequential BFS (Reference Implementation)

extension DenseGraph {
    /// Sequential BFS for correctness comparison.
    ///
    /// This is a reference implementation to validate parallel BFS results.
    public func computeReachableSequential() -> Set<Int> {
        guard !roots.isEmpty else { return [] }

        var visited = Bitmap(size: nodeCount)
        var queue: [Int] = []
        queue.reserveCapacity(nodeCount)

        // Initialize with roots
        for root in roots {
            if visited.testAndSet(root) {
                queue.append(root)
            }
        }

        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1

            for neighbor in adjacency[current] {
                if visited.testAndSet(neighbor) {
                    queue.append(neighbor)
                }
            }
        }

        return Set(visited.allSetBits())
    }
}
