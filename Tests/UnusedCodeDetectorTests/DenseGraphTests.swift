//
//  DenseGraphTests.swift
//  SwiftStaticAnalysis
//
//  Tests for DenseGraph representation.
//

import Foundation
import Testing

@testable import UnusedCodeDetector

@Suite("Dense Graph Tests")
struct DenseGraphTests {
    // MARK: - Construction

    @Test("Empty graph has correct properties")
    func emptyGraph() {
        let graph = DenseGraph(
            nodeIds: [],
            edges: [],
            rootIds: []
        )

        #expect(graph.nodeCount == 0)
        #expect(graph.edgeCount == 0)
        #expect(graph.roots.isEmpty)
        #expect(graph.isEmpty)
    }

    @Test("Node ID mapping is bijective")
    func nodeIdMappingBijective() {
        let nodeIds = ["A", "B", "C", "D"]
        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: [],
            rootIds: []
        )

        // Verify forward mapping
        for (index, nodeId) in nodeIds.enumerated() {
            #expect(graph.nodeToIndex[nodeId] == index)
        }

        // Verify reverse mapping
        for (index, nodeId) in graph.indexToNode.enumerated() {
            #expect(nodeIds[index] == nodeId)
        }
    }

    @Test("Adjacency correctly converted from string IDs")
    func adjacencyConversion() {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("A", "C"),
            ("B", "C"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: []
        )

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!
        let cIndex = graph.nodeToIndex["C"]!

        // Check adjacency for A
        #expect(graph.adjacency[aIndex].contains(bIndex))
        #expect(graph.adjacency[aIndex].contains(cIndex))
        #expect(graph.adjacency[aIndex].count == 2)

        // Check adjacency for B
        #expect(graph.adjacency[bIndex].contains(cIndex))
        #expect(graph.adjacency[bIndex].count == 1)

        // Check adjacency for C (no outgoing edges)
        #expect(graph.adjacency[cIndex].isEmpty)
    }

    @Test("Reverse adjacency matches forward adjacency")
    func reverseAdjacency() {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("A", "C"),
            ("B", "C"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: []
        )

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!
        let cIndex = graph.nodeToIndex["C"]!

        // Check reverse adjacency for B (A -> B)
        #expect(graph.reverseAdjacency[bIndex].contains(aIndex))

        // Check reverse adjacency for C (A -> C, B -> C)
        #expect(graph.reverseAdjacency[cIndex].contains(aIndex))
        #expect(graph.reverseAdjacency[cIndex].contains(bIndex))
        #expect(graph.reverseAdjacency[cIndex].count == 2)

        // Check reverse adjacency for A (no incoming edges)
        #expect(graph.reverseAdjacency[aIndex].isEmpty)
    }

    @Test("Root indices correctly identified")
    func rootIndices() {
        let nodeIds = ["A", "B", "C"]
        let rootIds: Set<String> = ["A", "C"]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: [],
            rootIds: rootIds
        )

        let aIndex = graph.nodeToIndex["A"]!
        let cIndex = graph.nodeToIndex["C"]!

        #expect(graph.roots.count == 2)
        #expect(graph.roots.contains(aIndex))
        #expect(graph.roots.contains(cIndex))
    }

    @Test("Edge count is correct")
    func edgeCount() {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("A", "C"),
            ("B", "C"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: []
        )

        #expect(graph.edgeCount == 3)
    }

    @Test("Invalid edges are skipped")
    func invalidEdgesSkipped() {
        let nodeIds = ["A", "B"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),  // Valid
            ("A", "X"),  // Invalid - X not in nodeIds
            ("Y", "B"),  // Invalid - Y not in nodeIds
            ("X", "Y"),  // Invalid - neither in nodeIds
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: []
        )

        #expect(graph.edgeCount == 1)
    }

    // MARK: - Helper Methods

    @Test("ToNodeIds converts indices back to strings")
    func toNodeIds() {
        let nodeIds = ["A", "B", "C"]
        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: [],
            rootIds: []
        )

        let indices: Set<Int> = [0, 2]
        let result = graph.toNodeIds(indices)

        #expect(result == ["A", "C"])
    }

    @Test("ToNodeIds array version works")
    func toNodeIdsArray() {
        let nodeIds = ["A", "B", "C"]
        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: [],
            rootIds: []
        )

        let indices = [0, 1, 2]
        let result = graph.toNodeIds(indices)

        #expect(result == ["A", "B", "C"])
    }

    @Test("TotalOutEdges calculates correctly")
    func totalOutEdges() {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("A", "C"),
            ("B", "C"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: []
        )

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!

        #expect(graph.totalOutEdges(from: [aIndex]) == 2)
        #expect(graph.totalOutEdges(from: [bIndex]) == 1)
        #expect(graph.totalOutEdges(from: [aIndex, bIndex]) == 3)
    }

    @Test("Neighbors and predecessors work")
    func neighborsAndPredecessors() {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("A", "C"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: []
        )

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!
        let cIndex = graph.nodeToIndex["C"]!

        #expect(graph.neighbors(of: aIndex) == [bIndex, cIndex])
        #expect(graph.predecessors(of: bIndex) == [aIndex])
    }

    // MARK: - Sequential BFS Reference Implementation

    @Test("Sequential BFS finds all reachable nodes")
    func sequentialBFS() {
        let nodeIds = ["A", "B", "C", "D", "E"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("B", "C"),
            ("C", "D"),
            // E is unreachable
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        let reachable = graph.computeReachableSequential()

        let aIndex = graph.nodeToIndex["A"]!
        let bIndex = graph.nodeToIndex["B"]!
        let cIndex = graph.nodeToIndex["C"]!
        let dIndex = graph.nodeToIndex["D"]!
        let eIndex = graph.nodeToIndex["E"]!

        #expect(reachable.contains(aIndex))
        #expect(reachable.contains(bIndex))
        #expect(reachable.contains(cIndex))
        #expect(reachable.contains(dIndex))
        #expect(!reachable.contains(eIndex))
        #expect(reachable.count == 4)
    }

    @Test("Sequential BFS with multiple roots")
    func sequentialBFSMultipleRoots() {
        let nodeIds = ["A", "B", "C", "D"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("C", "D"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A", "C"]
        )

        let reachable = graph.computeReachableSequential()
        #expect(reachable.count == 4)
    }

    @Test("Sequential BFS handles cycles")
    func sequentialBFSCycles() {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("B", "C"),
            ("C", "A"),  // Cycle back to A
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        let reachable = graph.computeReachableSequential()
        #expect(reachable.count == 3)
    }

    // MARK: - Statistics

    @Test("Statistics are computed correctly")
    func statistics() {
        let nodeIds = ["A", "B", "C"]
        let edges: [(from: String, to: String)] = [
            ("A", "B"),
            ("A", "C"),
            ("B", "C"),
        ]

        let graph = DenseGraph(
            nodeIds: nodeIds,
            edges: edges,
            rootIds: ["A"]
        )

        let stats = graph.statistics

        #expect(stats.nodeCount == 3)
        #expect(stats.edgeCount == 3)
        #expect(stats.rootCount == 1)
        #expect(stats.maxOutDegree == 2)  // A has 2 outgoing
        #expect(stats.maxInDegree == 2)  // C has 2 incoming
    }
}
