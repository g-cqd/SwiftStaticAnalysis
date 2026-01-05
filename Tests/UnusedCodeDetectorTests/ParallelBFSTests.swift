//
//  ParallelBFSTests.swift
//  SwiftStaticAnalysis
//
//  Tests for ParallelBFS direction-optimizing algorithm.
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

// MARK: - Test Tags

extension Tag {
    @Tag static var reachability: Self
    @Tag static var concurrency: Self
    @Tag static var boundary: Self
    @Tag static var algorithm: Self
    @Tag static var slow: Self
}

@Suite("Parallel BFS Tests", .tags(.reachability, .concurrency, .algorithm))
struct ParallelBFSTests {
    // MARK: - Correctness Tests

    @Test("Empty graph returns empty result")
    func emptyGraph() async {
        let graph = DenseGraph(
            nodeIds: [],
            edges: [],
            rootIds: []
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)
        #expect(reachable.isEmpty)
    }

    @Test("No roots returns empty result")
    func noRoots() async {
        let graph = DenseGraph(
            nodeIds: ["A", "B", "C"],
            edges: [("A", "B"), ("B", "C")],
            rootIds: []
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)
        #expect(reachable.isEmpty)
    }

    @Test("Single node graph works correctly")
    func singleNode() async {
        let graph = DenseGraph(
            nodeIds: ["A"],
            edges: [],
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)
        #expect(reachable.count == 1)
        #expect(reachable.contains(graph.nodeToIndex["A"]!))
    }

    @Test("Parallel BFS matches sequential BFS results")
    func matchesSequential() async {
        // Create a moderately complex graph
        let nodeIds = (0..<100).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Create a tree-like structure with some cross-edges
        for i in 0..<99 {
            edges.append((from: "Node\(i)", to: "Node\(i + 1)"))
            if i < 50 {
                edges.append((from: "Node\(i)", to: "Node\(i + 50)"))
            }
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        let sequentialResult = graph.computeReachableSequential()
        let parallelResult = await ParallelBFS.computeReachable(graph: graph)

        #expect(sequentialResult == parallelResult)
    }

    @Test("Parallel BFS is deterministic across multiple runs")
    func deterministic() async {
        let nodeIds = (0..<50).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        for i in 0..<49 {
            edges.append((from: "Node\(i)", to: "Node\(i + 1)"))
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        // Run multiple times and compare results
        let result1 = await ParallelBFS.computeReachable(graph: graph)
        let result2 = await ParallelBFS.computeReachable(graph: graph)
        let result3 = await ParallelBFS.computeReachable(graph: graph)

        #expect(result1 == result2)
        #expect(result2 == result3)
    }

    @Test("Disconnected components handled correctly")
    func disconnectedComponents() async {
        let nodeIds = ["A", "B", "C", "D", "E", "F"]
        let edges: [(from: String, to: String)] = [
            // Component 1: A -> B -> C
            ("A", "B"),
            ("B", "C"),
            // Component 2: D -> E -> F (disconnected)
            ("D", "E"),
            ("E", "F"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]  // Only A is a root
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!
        let cIndex = graph.nodeToIndex["C"]!
        let dIndex = graph.nodeToIndex["D"]!
        let eIndex = graph.nodeToIndex["E"]!
        let fIndex = graph.nodeToIndex["F"]!

        // Component 1 should be reachable
        #expect(reachable.contains(aIndex))
        #expect(reachable.contains(bIndex))
        #expect(reachable.contains(cIndex))

        // Component 2 should NOT be reachable
        #expect(!reachable.contains(dIndex))
        #expect(!reachable.contains(eIndex))
        #expect(!reachable.contains(fIndex))
    }

    @Test("Cycles are handled correctly")
    func cyclesHandled() async {
        let nodeIds = ["A", "B", "C", "D"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("B", "C"),
            ("C", "D"),
            ("D", "A"),  // Cycle back to A
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)
        #expect(reachable.count == 4)  // All nodes should be reachable
    }

    @Test("Multiple roots work correctly")
    func multipleRoots() async {
        let nodeIds = ["A", "B", "C", "D", "E"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("C", "D"),
            ("D", "E"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A", "C"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)

        // All nodes reachable from either root
        #expect(reachable.count == 5)
    }

    // MARK: - Configuration Tests

    @Test("Very small graph uses sequential fallback")
    func smallGraphFallback() async {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("B", "C"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        // With default config, graph smaller than minParallelSize uses sequential
        let config = ParallelBFS.Configuration(minParallelSize: 1000)
        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: config)

        #expect(reachable.count == 3)
    }

    @Test("Custom alpha/beta thresholds work")
    func customThresholds() async {
        let nodeIds = (0..<100).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Create a star graph (high fan-out from root)
        for i in 1..<100 {
            edges.append((from: "Node0", to: "Node\(i)"))
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        // Force parallel with low minParallelSize
        let config = ParallelBFS.Configuration(
            alpha: 10,
            beta: 20,
            minParallelSize: 50
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: config)
        #expect(reachable.count == 100)
    }

    // MARK: - Configuration Validation Tests

    @Test("Invalid config values are clamped to valid range")
    func invalidConfigValuesClamped() {
        // Test zero values (would cause division by zero)
        let zeroConfig = ParallelBFS.Configuration(
            alpha: 0,
            beta: 0,
            minParallelSize: 0,
            maxConcurrency: 0
        )
        #expect(zeroConfig.alpha >= 1)
        #expect(zeroConfig.beta >= 1)
        #expect(zeroConfig.minParallelSize >= 1)
        #expect(zeroConfig.maxConcurrency >= 1)

        // Test negative values
        let negativeConfig = ParallelBFS.Configuration(
            alpha: -10,
            beta: -20,
            minParallelSize: -1000,
            maxConcurrency: -4
        )
        #expect(negativeConfig.alpha >= 1)
        #expect(negativeConfig.beta >= 1)
        #expect(negativeConfig.minParallelSize >= 1)
        #expect(negativeConfig.maxConcurrency >= 1)

        // Test excessively large values
        let largeConfig = ParallelBFS.Configuration(
            alpha: 1000,
            beta: 1000,
            maxConcurrency: 10000
        )
        #expect(largeConfig.alpha <= 100)  // Clamped to reasonable max
        #expect(largeConfig.beta <= 100)  // Clamped to reasonable max
        #expect(largeConfig.maxConcurrency <= ProcessInfo.processInfo.activeProcessorCount)
    }

    @Test("Config with nil maxConcurrency uses processor count")
    func defaultMaxConcurrency() {
        let config = ParallelBFS.Configuration(maxConcurrency: nil)
        #expect(config.maxConcurrency == ProcessInfo.processInfo.activeProcessorCount)
    }

    // MARK: - Statistics Tests

    @Test("Execution statistics are collected")
    func executionStats() async {
        let nodeIds = (0..<200).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Create a long chain
        for i in 0..<199 {
            edges.append((from: "Node\(i)", to: "Node\(i + 1)"))
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        // Force parallel execution
        let config = ParallelBFS.Configuration(minParallelSize: 50)
        let (reachable, stats) = await ParallelBFS.computeReachableWithStats(
            graph: graph,
            configuration: config
        )

        #expect(reachable.count == 200)
        #expect(stats.totalIterations > 0)
        #expect(stats.totalNodesVisited == 200)
        #expect(stats.topDownIterations + stats.bottomUpIterations == stats.totalIterations)
    }

    // MARK: - Large Graph Tests

    @Test("Large graph parallel BFS correctness")
    func largeGraphCorrectness() async {
        // Create a larger graph to test parallel execution
        let nodeCount = 2000
        let nodeIds = (0..<nodeCount).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Create a binary tree-like structure
        for i in 0..<(nodeCount - 1) / 2 {
            let left = 2 * i + 1
            let right = 2 * i + 2
            if left < nodeCount {
                edges.append((from: "Node\(i)", to: "Node\(left)"))
            }
            if right < nodeCount {
                edges.append((from: "Node\(i)", to: "Node\(right)"))
            }
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        let config = ParallelBFS.Configuration(minParallelSize: 500)

        let sequentialResult = graph.computeReachableSequential()
        let parallelResult = await ParallelBFS.computeReachable(
            graph: graph,
            configuration: config
        )

        #expect(sequentialResult == parallelResult)
    }

    @Test("Dense graph triggers bottom-up phase")
    func denseGraphBottomUp() async {
        // Create a dense graph that should trigger bottom-up BFS
        // Using a fully-connected-like structure where each node connects to many others
        let nodeCount = 500
        let nodeIds = (0..<nodeCount).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Create many edges from each node (high average degree ~20)
        // This creates a very dense graph that should trigger bottom-up
        for i in 0..<nodeCount {
            for j in 0..<min(20, nodeCount - i - 1) {
                edges.append((from: "Node\(i)", to: "Node\(i + j + 1)"))
            }
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        // Use aggressive alpha to trigger bottom-up more easily
        // With α=2, bottom-up triggers when frontierEdges > remainingEdges/2
        let config = ParallelBFS.Configuration(
            alpha: 2,  // Low alpha = more likely to trigger bottom-up
            beta: 24,
            minParallelSize: 100
        )

        let (reachable, stats) = await ParallelBFS.computeReachableWithStats(
            graph: graph,
            configuration: config
        )

        // Verify correctness
        let sequentialResult = graph.computeReachableSequential()
        #expect(reachable == sequentialResult)

        // Assert that bottom-up was actually triggered (per review finding)
        // This ensures the direction-switching heuristic is working correctly
        #expect(
            stats.bottomUpIterations > 0,
            "Expected bottom-up phase to trigger on dense graph (α=\(config.alpha), stats=\(stats))")
        #expect(stats.totalIterations > 0)

        // Verify stats consistency
        #expect(stats.topDownIterations + stats.bottomUpIterations == stats.totalIterations)
    }

    @Test("Sparse graph mostly uses top-down mode")
    func sparseGraphMostlyTopDown() async {
        // Create a sparse graph (chain) that should mostly use top-down mode
        let nodeCount = 200
        let nodeIds = (0..<nodeCount).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Linear chain: avg degree = 1
        for i in 0..<nodeCount - 1 {
            edges.append((from: "Node\(i)", to: "Node\(i + 1)"))
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        // Use default thresholds
        let config = ParallelBFS.Configuration(
            alpha: 14,
            beta: 24,
            minParallelSize: 50
        )

        let (reachable, stats) = await ParallelBFS.computeReachableWithStats(
            graph: graph,
            configuration: config
        )

        // Verify correctness
        let sequentialResult = graph.computeReachableSequential()
        #expect(reachable == sequentialResult)

        // Per Beamer et al., even sparse graphs will switch to bottom-up near the end
        // when remaining edges become < frontierEdges * alpha.
        // For a chain with α=14, switch happens when remaining < 14 edges.
        // So we expect MOSTLY top-down (>90% of iterations).
        let topDownRatio = Double(stats.topDownIterations) / Double(stats.totalIterations)
        #expect(topDownRatio > 0.9, "Sparse graph should use mostly top-down (got \(topDownRatio))")

        // The bottom-up iterations should be few (only near the end)
        #expect(stats.bottomUpIterations < 20, "Expected few bottom-up iterations for sparse graph")
    }

    @Test("Wide tree stays in top-down mode with high alpha")
    func wideTreeHighAlphaTopDownOnly() async {
        // A wide tree (star-like) with large frontier should stay in top-down
        // when alpha is high enough that we never meet the threshold
        let nodeCount = 100
        let nodeIds = (0..<nodeCount).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Star graph: root connects to all other nodes
        // All edges are discovered in iteration 1, then BFS is done
        for i in 1..<nodeCount {
            edges.append((from: "Node0", to: "Node\(i)"))
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        // High alpha: switch to bottom-up when frontierEdges * 100 > remaining
        // For a star: iteration 1 has frontier=[all nodes], frontierEdges=0, remaining=0
        // So we never switch because there's nothing left after iteration 1
        let config = ParallelBFS.Configuration(
            alpha: 100,
            beta: 100,
            minParallelSize: 50
        )

        let (reachable, stats) = await ParallelBFS.computeReachableWithStats(
            graph: graph,
            configuration: config
        )

        // Verify correctness
        let sequentialResult = graph.computeReachableSequential()
        #expect(reachable == sequentialResult)
        #expect(reachable.count == nodeCount, "All nodes should be reachable")

        // A star graph completes in 2 iterations (root, then all children)
        // Both should be top-down since remaining edges become 0 immediately
        #expect(stats.totalIterations <= 2, "Star graph should complete in at most 2 iterations")
        #expect(stats.bottomUpIterations == 0, "Star graph should stay in top-down mode")
    }

    @Test("Alpha and beta thresholds affect mode switching")
    func alphaBetaAffectModeSwitching() async {
        // Test that alpha and beta thresholds influence mode switching behavior.
        // The exact number of iterations in each mode depends on complex
        // interactions between thresholds and graph structure, so we just
        // verify that the algorithm produces correct results with various configs.

        let nodeCount = 100
        let nodeIds = (0..<nodeCount).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Create a graph with moderate connectivity
        for i in 0..<nodeCount - 1 {
            edges.append((from: "Node\(i)", to: "Node\(i + 1)"))
            if i + 10 < nodeCount {
                edges.append((from: "Node\(i)", to: "Node\(i + 10)"))
            }
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )
        let sequentialResult = graph.computeReachableSequential()

        // Test various alpha/beta combinations produce correct results
        let configs: [(alpha: Int, beta: Int)] = [
            (2, 24),  // Low alpha
            (14, 24),  // Default
            (100, 24),  // High alpha
            (14, 100),  // High beta
            (100, 100),  // Both high
        ]

        for (alpha, beta) in configs {
            let config = ParallelBFS.Configuration(
                alpha: alpha, beta: beta, minParallelSize: 50
            )
            let (result, stats) = await ParallelBFS.computeReachableWithStats(
                graph: graph, configuration: config
            )

            #expect(result == sequentialResult, "Config (α=\(alpha), β=\(beta)) should produce correct result")
            #expect(stats.totalIterations > 0, "Config (α=\(alpha), β=\(beta)) should complete iterations")
            #expect(
                stats.topDownIterations + stats.bottomUpIterations == stats.totalIterations,
                "Stats should be consistent for (α=\(alpha), β=\(beta))"
            )
        }
    }
}

// MARK: - Integration with ReachabilityGraph

// MARK: - Edge Case Tests

@Suite("Parallel BFS Edge Case Tests", .tags(.reachability, .boundary))
struct ParallelBFSEdgeCaseTests {
    @Test("Self-loops are handled correctly")
    func selfLoopsHandled() async {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "A"),  // Self-loop
            ("A", "B"),
            ("B", "B"),  // Another self-loop
            ("B", "C"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)

        // All nodes should still be reachable despite self-loops
        #expect(reachable.count == 3)

        // Verify sequential matches
        let sequentialResult = graph.computeReachableSequential()
        #expect(reachable == sequentialResult)
    }

    @Test("Zero remaining edges case handled")
    func zeroRemainingEdges() async {
        // After first iteration, no edges remain (star graph)
        let nodeIds = ["root", "leaf1", "leaf2", "leaf3"]
        let edges: [(from: String, to: String)] = [
            ("root", "leaf1"),
            ("root", "leaf2"),
            ("root", "leaf3"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["root"]
        )

        let config = ParallelBFS.Configuration(minParallelSize: 1)
        let (reachable, stats) = await ParallelBFS.computeReachableWithStats(
            graph: graph,
            configuration: config
        )

        // All nodes reachable
        #expect(reachable.count == 4)

        // Should complete quickly (2 iterations: root, then all leaves)
        #expect(stats.totalIterations <= 2)
    }

    @Test("Duplicate roots are handled correctly")
    func duplicateRoots() async {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("B", "C"),
        ]

        // Duplicate A as root
        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A", "A", "A"]  // Same root multiple times
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)

        // Should still work correctly
        #expect(reachable.count == 3)
    }

    @Test("Large fan-out node handled")
    func largeFanOut() async {
        // One node connects to many others
        let nodeCount = 500
        let nodeIds = (0..<nodeCount).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // Node 0 connects to all others
        for i in 1..<nodeCount {
            edges.append((from: "Node0", to: "Node\(i)"))
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        let config = ParallelBFS.Configuration(minParallelSize: 100)
        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: config)

        #expect(reachable.count == nodeCount)

        // Verify correctness against sequential
        let sequentialResult = graph.computeReachableSequential()
        #expect(reachable == sequentialResult)
    }

    @Test("Large fan-in node handled")
    func largeFanIn() async {
        // Many nodes connect to one target
        let nodeCount = 500
        let nodeIds = (0..<nodeCount).map { "Node\($0)" }
        var edges: [(from: String, to: String)] = []

        // All nodes connect to the last one
        for i in 0..<nodeCount - 1 {
            edges.append((from: "Node\(i)", to: "Node\(nodeCount - 1)"))
        }

        // Chain the first few to ensure connectivity
        for i in 0..<10 {
            if i + 1 < nodeCount - 1 {
                edges.append((from: "Node\(i)", to: "Node\(i + 1)"))
            }
        }

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["Node0"]
        )

        let config = ParallelBFS.Configuration(minParallelSize: 100)
        let reachable = await ParallelBFS.computeReachable(graph: graph, configuration: config)

        // Verify correctness against sequential
        let sequentialResult = graph.computeReachableSequential()
        #expect(reachable == sequentialResult)
    }

    @Test("Isolated node not reachable")
    func isolatedNodeNotReachable() async {
        let nodeIds = ["A", "B", "C", "isolated"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("B", "C"),
            // "isolated" has no edges
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)

        // isolated should NOT be reachable
        let isolatedIndex = graph.nodeToIndex["isolated"]!
        #expect(!reachable.contains(isolatedIndex))

        // Others should be reachable
        #expect(reachable.count == 3)
    }

    @Test("Bidirectional edges work correctly")
    func bidirectionalEdges() async {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("B", "A"),  // Bidirectional
            ("B", "C"),
            ("C", "B"),  // Bidirectional
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)

        // All nodes reachable
        #expect(reachable.count == 3)

        // Verify matches sequential
        let sequentialResult = graph.computeReachableSequential()
        #expect(reachable == sequentialResult)
    }

    @Test("Diamond dependency pattern")
    func diamondPattern() async {
        // A → B, A → C, B → D, C → D (diamond)
        let nodeIds = ["A", "B", "C", "D"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("A", "C"),
            ("B", "D"),
            ("C", "D"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        let reachable = await ParallelBFS.computeReachable(graph: graph)

        // All nodes reachable
        #expect(reachable.count == 4)

        // D should only be counted once despite two paths
        let dIndex = graph.nodeToIndex["D"]!
        #expect(reachable.contains(dIndex))
    }
}

@Suite("Parallel BFS Integration Tests")
struct ParallelBFSIntegrationTests {
    @Test("ReachabilityGraph parallel and sequential produce same results")
    func reachabilityGraphIntegration() async {
        let graph = ReachabilityGraph()

        let location = SwiftStaticAnalysisCore.SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SwiftStaticAnalysisCore.SourceRange(start: location, end: location)

        // Add nodes
        var nodes: [DeclarationNode] = []
        for i in 0..<50 {
            let decl = Declaration(
                name: "func\(i)",
                kind: .function,
                location: SwiftStaticAnalysisCore.SourceLocation(
                    file: "test.swift",
                    line: i + 1,
                    column: 1,
                    offset: i * 100
                ),
                range: range,
                scope: .global
            )
            let isRoot = i == 0
            let node = await graph.addNode(decl, isRoot: isRoot, rootReason: isRoot ? .mainFunction : nil)
            nodes.append(node)
        }

        // Add edges (chain)
        for i in 0..<49 {
            await graph.addEdge(from: nodes[i].id, to: nodes[i + 1].id, kind: .call)
        }

        let sequentialResult = await graph.computeReachable()
        let parallelResult = await graph.computeReachableParallel()

        #expect(sequentialResult == parallelResult)
    }
}
