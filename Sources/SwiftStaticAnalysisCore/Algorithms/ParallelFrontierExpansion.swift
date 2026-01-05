//  ParallelFrontierExpansion.swift
//  SwiftStaticAnalysis
//  MIT License

import Algorithms
import Foundation

// MARK: - ParallelFrontierExpansion

/// Generic parallel frontier expansion for BFS-like graph traversals.
///
/// This utility provides a reusable parallel expansion pattern that can be used
/// with any graph representation that provides adjacency lists and atomic visited tracking.
public enum ParallelFrontierExpansion {
    /// Expand a frontier in parallel using chunked TaskGroup processing.
    ///
    /// This implements the top-down BFS expansion pattern where each frontier node
    /// expands outward to its neighbors in parallel.
    ///
    /// - Parameters:
    ///   - frontier: Current frontier nodes to expand.
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - getNeighbors: Closure to get neighbors for a node.
    ///   - testAndSetVisited: Atomic closure that returns true if node was newly visited.
    /// - Returns: Next frontier of newly discovered nodes.
    public static func expandParallel(
        frontier: [Int],
        maxConcurrency: Int,
        getNeighbors: @escaping @Sendable (Int) -> [Int],
        testAndSetVisited: @escaping @Sendable (Int) -> Bool
    ) async -> [Int] {
        let chunkSize = max(1, frontier.count / maxConcurrency)

        return await withTaskGroup(of: [Int].self) { group in
            for chunk in frontier.chunks(ofCount: chunkSize) {
                group.addTask {
                    var localNext: [Int] = []
                    for node in chunk {
                        for neighbor in getNeighbors(node) {
                            if testAndSetVisited(neighbor) {
                                localNext.append(neighbor)
                            }
                        }
                    }
                    return localNext
                }
            }

            var result: [Int] = []
            for await partial in group {
                result.append(contentsOf: partial)
            }
            return result
        }
    }

    /// Expand a range of nodes in parallel using chunked TaskGroup processing.
    ///
    /// This implements the bottom-up BFS expansion pattern where unvisited nodes
    /// check if they should be added to the frontier.
    ///
    /// - Parameters:
    ///   - nodeCount: Total number of nodes in the graph.
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - shouldExpand: Closure that returns true if a node should be added to next frontier.
    /// - Returns: Next frontier of newly discovered nodes.
    public static func expandRangeParallel(
        nodeCount: Int,
        maxConcurrency: Int,
        shouldExpand: @escaping @Sendable (Int) -> Bool
    ) async -> [Int] {
        let chunkSize = max(1, nodeCount / maxConcurrency)

        return await withTaskGroup(of: [Int].self) { group in
            for chunk in (0..<nodeCount).chunks(ofCount: chunkSize) {
                group.addTask {
                    var localNext: [Int] = []
                    for node in chunk {
                        if shouldExpand(node) {
                            localNext.append(node)
                        }
                    }
                    return localNext
                }
            }

            var result: [Int] = []
            for await partial in group {
                result.append(contentsOf: partial)
            }
            return result
        }
    }
}
