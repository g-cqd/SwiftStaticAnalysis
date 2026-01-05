//
//  ParallelConnectedComponents.swift
//  SwiftStaticAnalysis
//
//  Parallel connected component finding for clone graphs.
//  Directly applies patterns from ParallelBFS:
//  - AtomicBitmap for lock-free visited tracking
//  - Top-down chunked expansion
//  - Direction-optimizing for dense graphs
//  - Atomic root claiming for global parallelism
//

import Algorithms
import Collections
import Foundation
import SwiftStaticAnalysisCore  // For ParallelFrontierExpansion
import UnusedCodeDetector  // For AtomicBitmap, Bitmap

// MARK: - ParallelConnectedComponents

/// Parallel connected component finding for clone graphs.
///
/// ## Design (mirrors ParallelBFS)
///
/// - `AtomicBitmap` for thread-safe visited tracking
/// - Top-down chunked expansion (mirrors `topDownStep`)
/// - Direction-optimizing for dense graphs (mirrors bottom-up heuristics)
/// - Atomic `testAndSet` to "claim" component roots
///
/// ## Performance Characteristics
///
/// - Small graphs (< minParallelSize): Sequential fallback
/// - Large graphs: Parallel BFS per component
/// - Dense graphs: Direction-optimizing reduces edge checks
public enum ParallelConnectedComponents {
    // MARK: - Configuration

    /// Configuration for parallel connected component finding.
    public struct Configuration: Sendable {
        // MARK: Lifecycle

        public init(
            minParallelSize: Int = 100,
            maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
            alpha: Int = 14
        ) {
            self.minParallelSize = max(1, minParallelSize)
            self.maxConcurrency = max(1, maxConcurrency)
            self.alpha = max(1, alpha)
        }

        // MARK: Public

        /// Default configuration.
        public static let `default` = Configuration()

        /// Minimum graph size to use parallel algorithm.
        public var minParallelSize: Int

        /// Maximum concurrent tasks.
        public var maxConcurrency: Int

        /// Alpha threshold for switching to bottom-up.
        /// Switch when: frontierEdges * alpha > remainingEdges
        public var alpha: Int
    }

    // MARK: - Main Entry Point

    /// Find connected components using parallel BFS.
    ///
    /// Uses atomic visited bitmap to "claim" component roots, enabling
    /// concurrent BFS traversals without double-visiting.
    ///
    /// - Parameters:
    ///   - graph: Clone similarity graph.
    ///   - configuration: Parallel configuration.
    /// - Returns: Array of components (each component is an array of node indices).
    public static func findComponents(
        graph: CloneSimilarityGraph,
        configuration: Configuration = .default
    ) async -> [[Int]] {
        let nodeCount = graph.nodeCount
        guard nodeCount > 0, graph.edgeCount > 0 else { return [] }

        // Use sequential for small graphs (overhead dominates)
        if nodeCount < configuration.minParallelSize {
            return findComponentsSequential(graph: graph)
        }

        // AtomicBitmap for thread-safe visited tracking (mirrors ParallelBFS)
        let visited = AtomicBitmap(size: nodeCount)
        var components: [[Int]] = []

        // Sequential outer loop to find component roots
        // Each root is "claimed" via atomic testAndSet
        for seed in 0..<nodeCount {
            // Skip nodes with no edges (isolated documents)
            guard !graph.adjacency[seed].isEmpty else { continue }

            // Atomic claim of this root
            guard visited.testAndSet(seed) else { continue }

            // Parallel BFS for this component
            let component = await parallelBFS(
                seed: seed,
                graph: graph,
                visited: visited,
                configuration: configuration
            )

            // Only include components with 2+ nodes (actual clone groups)
            if component.count >= 2 {
                components.append(component)
            }
        }

        return components
    }

    // MARK: - Parallel BFS

    /// Parallel BFS for a single component (mirrors ParallelBFS.computeReachable).
    private static func parallelBFS(
        seed: Int,
        graph: CloneSimilarityGraph,
        visited: AtomicBitmap,
        configuration: Configuration
    ) async -> [Int] {
        var frontier = [seed]
        var component = [seed]

        // Track remaining edges for direction-optimizing (mirrors Beamer et al.)
        var remainingEdges = graph.edgeCount

        while !frontier.isEmpty {
            let frontierEdges = graph.totalOutEdges(from: frontier)

            // Direction-optimizing: use bottom-up for large frontiers
            // In undirected clone graph, reverse adjacency = adjacency
            let useBottomUp = shouldSwitchToBottomUp(
                frontierEdges: frontierEdges,
                remainingEdges: remainingEdges,
                alpha: configuration.alpha
            )

            let nextFrontier: [Int]
            if frontier.count < configuration.maxConcurrency * 2 {
                // Sequential for small frontiers
                nextFrontier = expandSequential(frontier, graph: graph, visited: visited)
            } else if useBottomUp {
                // Bottom-up: unvisited nodes check if any neighbor is in frontier
                let frontierBitmap = Bitmap(size: graph.nodeCount, setting: frontier)
                nextFrontier = await bottomUpExpand(
                    frontierBitmap: frontierBitmap,
                    graph: graph,
                    visited: visited,
                    maxConcurrency: configuration.maxConcurrency
                )
            } else {
                // Top-down: parallel frontier expansion (mirrors topDownStep)
                nextFrontier = await topDownExpand(
                    frontier,
                    graph: graph,
                    visited: visited,
                    maxConcurrency: configuration.maxConcurrency
                )
            }

            // Update remaining edges estimate
            remainingEdges -= frontierEdges

            component.append(contentsOf: nextFrontier)
            frontier = nextFrontier
        }

        return component
    }

    // MARK: - Direction Switching

    /// Should switch from top-down to bottom-up? (mirrors ParallelBFS heuristic)
    private static func shouldSwitchToBottomUp(
        frontierEdges: Int,
        remainingEdges: Int,
        alpha: Int
    ) -> Bool {
        guard remainingEdges > 0 else { return false }
        return frontierEdges * alpha > remainingEdges
    }

    // MARK: - Expansion Methods

    /// Sequential expansion for small frontiers.
    private static func expandSequential(
        _ frontier: [Int],
        graph: CloneSimilarityGraph,
        visited: AtomicBitmap
    ) -> [Int] {
        var next: [Int] = []
        for node in frontier {
            for neighbor in graph.adjacency[node] {
                if visited.testAndSet(neighbor) {
                    next.append(neighbor)
                }
            }
        }
        return next
    }

    /// Top-down parallel expansion (uses shared ParallelFrontierExpansion).
    private static func topDownExpand(
        _ frontier: [Int],
        graph: CloneSimilarityGraph,
        visited: AtomicBitmap,
        maxConcurrency: Int
    ) async -> [Int] {
        await ParallelFrontierExpansion.expandParallel(
            frontier: frontier,
            maxConcurrency: maxConcurrency,
            getNeighbors: { graph.adjacency[$0] },
            testAndSetVisited: { visited.testAndSet($0) }
        )
    }

    /// Bottom-up parallel expansion (mirrors ParallelBFS.bottomUpStep).
    ///
    /// For undirected clone graphs, reverse adjacency = adjacency,
    /// so we just check if any neighbor is in the frontier.
    private static func bottomUpExpand(
        frontierBitmap: Bitmap,
        graph: CloneSimilarityGraph,
        visited: AtomicBitmap,
        maxConcurrency: Int
    ) async -> [Int] {
        let nodeCount = graph.nodeCount
        let chunkSize = max(1, nodeCount / maxConcurrency)

        return await withTaskGroup(of: [Int].self) { group in
            for chunk in (0..<nodeCount).chunks(ofCount: chunkSize) {
                group.addTask {
                    var localNext: [Int] = []

                    for node in chunk {
                        // Skip already visited
                        guard !visited.test(node) else { continue }

                        // Check if any neighbor is in frontier
                        for neighbor in graph.adjacency[node] {
                            if frontierBitmap.test(neighbor) {
                                if visited.testAndSet(node) {
                                    localNext.append(node)
                                }
                                break  // Only need one neighbor in frontier
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

    // MARK: - Sequential Fallback

    /// Sequential fallback for small graphs.
    private static func findComponentsSequential(graph: CloneSimilarityGraph) -> [[Int]] {
        var visited = Bitmap(size: graph.nodeCount)
        var components: [[Int]] = []

        for seed in 0..<graph.nodeCount {
            guard !graph.adjacency[seed].isEmpty else { continue }
            guard !visited.test(seed) else { continue }
            visited.set(seed)

            var component = [seed]
            var queue = Deque([seed])  // O(1) popFirst

            while let node = queue.popFirst() {
                for neighbor in graph.adjacency[node] where !visited.test(neighbor) {
                    visited.set(neighbor)
                    queue.append(neighbor)
                    component.append(neighbor)
                }
            }

            if component.count >= 2 {
                components.append(component)
            }
        }

        return components
    }
}

// MARK: - Execution Statistics

extension ParallelConnectedComponents {
    /// Statistics from component finding.
    public struct ExecutionStats: Sendable {
        /// Number of components found.
        public var componentCount: Int = 0

        /// Largest component size.
        public var largestComponentSize: Int = 0

        /// Total nodes in all components.
        public var totalNodesInComponents: Int = 0

        /// Whether parallel processing was used.
        public var usedParallel: Bool = false
    }

    /// Find connected components with execution statistics.
    public static func findComponentsWithStats(
        graph: CloneSimilarityGraph,
        configuration: Configuration = .default
    ) async -> (components: [[Int]], stats: ExecutionStats) {
        var stats = ExecutionStats()

        let components = await findComponents(graph: graph, configuration: configuration)

        stats.componentCount = components.count
        stats.largestComponentSize = components.map(\.count).max() ?? 0
        stats.totalNodesInComponents = components.reduce(0) { $0 + $1.count }
        stats.usedParallel = graph.nodeCount >= configuration.minParallelSize

        return (components, stats)
    }
}
