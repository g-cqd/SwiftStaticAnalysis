//  DependencyExtractionTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Dependency Extraction Tests")
struct DependencyExtractionTests {
    @Test("DependencyExtractor initialization")
    func extractorInitialization() {
        let extractor = DependencyExtractor()
        #expect(extractor.configuration.treatPublicAsRoot == true)
    }

    @Test("Custom extraction configuration")
    func customConfig() {
        let config = DependencyExtractionConfiguration(
            treatPublicAsRoot: false,
            treatObjcAsRoot: false,
            treatTestsAsRoot: false,
        )
        let extractor = DependencyExtractor(configuration: config)
        #expect(extractor.configuration.treatPublicAsRoot == false)
    }

    @Test("Strict configuration")
    func strictConfig() {
        let config = DependencyExtractionConfiguration.strict
        #expect(config.treatPublicAsRoot == false)
        #expect(config.treatObjcAsRoot == true)
    }

    @Test("Build graph from analysis result")
    func buildGraphFromResult() async {
        let extractor = DependencyExtractor()
        let location = SourceLocation(file: "test.swift", line: 1, column: 1)
        let range = SourceRange(start: location, end: SourceLocation(file: "test.swift", line: 10, column: 1))

        // Create a simple analysis result with declarations and references
        let decl1 = Declaration(
            name: "MyClass",
            kind: .class,
            accessLevel: .public,
            modifiers: [],
            location: location,
            range: range,
            scope: .global
        )

        let decl2 = Declaration(
            name: "myMethod",
            kind: .method,
            accessLevel: .internal,
            modifiers: [],
            location: SourceLocation(file: "test.swift", line: 5, column: 5),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 5, column: 5),
                end: SourceLocation(file: "test.swift", line: 8, column: 5)
            ),
            scope: ScopeID("MyClass")
        )

        var declIndex = DeclarationIndex()
        declIndex.add(decl1)
        declIndex.add(decl2)

        let refIndex = ReferenceIndex()
        let scopeTree = ScopeTree()

        let result = AnalysisResult(
            files: ["test.swift"],
            declarations: declIndex,
            references: refIndex,
            scopes: scopeTree,
            statistics: AnalysisStatistics(
                fileCount: 1,
                totalLines: 10,
                declarationCount: 2,
                referenceCount: 0,
                declarationsByKind: [:],
                analysisTime: 0
            )
        )

        let graph = await extractor.buildGraph(from: result)

        // Should have 2 nodes (MyClass and myMethod)
        let nodeCount = await graph.nodeCount
        #expect(nodeCount == 2)

        // MyClass should be a root (public)
        let rootNodes = await graph.rootNodes
        #expect(rootNodes.count >= 1)
    }

    @Test("Batch edge insertion")
    func batchEdgeInsertion() async {
        let graph = ReachabilityGraph()

        // Add nodes
        let decl1 = Declaration(
            name: "A",
            kind: .class,
            accessLevel: .internal,
            modifiers: [],
            location: SourceLocation(file: "test.swift", line: 1, column: 1),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 1, column: 1),
                end: SourceLocation(file: "test.swift", line: 5, column: 1)
            ),
            scope: .global
        )

        let decl2 = Declaration(
            name: "B",
            kind: .class,
            accessLevel: .internal,
            modifiers: [],
            location: SourceLocation(file: "test.swift", line: 10, column: 1),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 10, column: 1),
                end: SourceLocation(file: "test.swift", line: 15, column: 1)
            ),
            scope: .global
        )

        await graph.addNode(decl1, isRoot: true, rootReason: .publicAPI)
        await graph.addNode(decl2, isRoot: false)

        // Create batch of edges
        let nodeA = DeclarationNode(declaration: decl1)
        let nodeB = DeclarationNode(declaration: decl2)

        let edges = [
            DependencyEdge(from: nodeA.id, to: nodeB.id, kind: .call),
            DependencyEdge(from: nodeA.id, to: nodeB.id, kind: .typeReference),
        ]

        // Batch insert
        await graph.addEdges(edges)

        // B should now be reachable from A
        let isReachable = await graph.isReachable(decl2)
        #expect(isReachable == true)

        let edgeCount = await graph.edgeCount
        #expect(edgeCount == 2)
    }

    // MARK: - Parallel Edge Computation Correctness Tests

    @Test("Parallel edge computation is deterministic")
    func parallelEdgeComputationDeterministic() async {
        // Run the same analysis multiple times and verify identical results
        let extractor = DependencyExtractor()
        let result = createLargeAnalysisResult(declarationCount: 100)

        // Run 3 times and compare results
        let graph1 = await extractor.buildGraph(from: result)
        let graph2 = await extractor.buildGraph(from: result)
        let graph3 = await extractor.buildGraph(from: result)

        let nodeCount1 = await graph1.nodeCount
        let nodeCount2 = await graph2.nodeCount
        let nodeCount3 = await graph3.nodeCount

        #expect(nodeCount1 == nodeCount2)
        #expect(nodeCount2 == nodeCount3)

        let edgeCount1 = await graph1.edgeCount
        let edgeCount2 = await graph2.edgeCount
        let edgeCount3 = await graph3.edgeCount

        #expect(edgeCount1 == edgeCount2)
        #expect(edgeCount2 == edgeCount3)

        // Verify reachability is identical
        let unreachable1 = await graph1.computeUnreachable()
        let unreachable2 = await graph2.computeUnreachable()
        let unreachable3 = await graph3.computeUnreachable()

        #expect(unreachable1.count == unreachable2.count)
        #expect(unreachable2.count == unreachable3.count)
    }

    @Test("Parallel edge computation preserves all edges")
    func parallelEdgeComputationPreservesEdges() async {
        // Create a graph with known structure and verify all edges are present
        // Create a chain: A -> B -> C -> D
        var declarations: [Declaration] = []
        for i in 0..<4 {
            let name = ["A", "B", "C", "D"][i]
            let decl = Declaration(
                name: name,
                kind: .class,
                accessLevel: i == 0 ? .public : .internal,
                modifiers: [],
                location: SourceLocation(file: "test.swift", line: i * 10 + 1, column: 1),
                range: SourceRange(
                    start: SourceLocation(file: "test.swift", line: i * 10 + 1, column: 1),
                    end: SourceLocation(file: "test.swift", line: i * 10 + 9, column: 1)
                ),
                scope: .global,
                typeAnnotation: i < 3 ? ["B", "C", "D"][i] : nil
            )
            declarations.append(decl)
        }

        var declIndex = DeclarationIndex()
        for decl in declarations {
            declIndex.add(decl)
        }

        let result = AnalysisResult(
            files: ["test.swift"],
            declarations: declIndex,
            references: ReferenceIndex(),
            scopes: ScopeTree(),
            statistics: AnalysisStatistics(
                fileCount: 1,
                totalLines: 40,
                declarationCount: 4,
                referenceCount: 0,
                declarationsByKind: [:],
                analysisTime: 0
            )
        )

        let extractor = DependencyExtractor()
        let graph = await extractor.buildGraph(from: result)

        // A should be a root (public)
        let roots = await graph.rootNodes
        #expect(roots.contains { $0.declaration.name == "A" })

        // All nodes should be reachable through the chain
        for decl in declarations {
            let isReachable = await graph.isReachable(decl)
            #expect(isReachable == true, "Declaration \(decl.name) should be reachable")
        }
    }

    @Test("Large graph parallel processing maintains correctness")
    func largeGraphParallelCorrectness() async {
        // Test with a larger dataset to stress-test parallel processing
        let result = createLargeAnalysisResult(declarationCount: 500)

        let extractor = DependencyExtractor()
        let graph = await extractor.buildGraph(from: result)

        let nodeCount = await graph.nodeCount
        #expect(nodeCount == 500)

        // Verify roots are correctly identified
        let roots = await graph.rootNodes
        #expect(roots.count > 0)

        // Verify BFS reachability terminates and produces valid results
        let unreachable = await graph.computeUnreachable()
        let reachableCount = nodeCount - unreachable.count

        // At least roots should be reachable
        #expect(reachableCount >= roots.count)
    }

    @Test("Batch edge insertion is atomic")
    func batchEdgeInsertionAtomic() async {
        let graph = ReachabilityGraph()
        let location = SourceLocation(file: "test.swift", line: 1, column: 1)
        let range = SourceRange(start: location, end: location)

        // Add 100 nodes
        var declarations: [Declaration] = []
        for i in 0..<100 {
            let decl = Declaration(
                name: "Node\(i)",
                kind: .class,
                accessLevel: i == 0 ? .public : .internal,
                location: SourceLocation(file: "test.swift", line: i + 1, column: 1),
                range: range,
                scope: .global
            )
            declarations.append(decl)
            await graph.addNode(decl, isRoot: i == 0, rootReason: i == 0 ? .publicAPI : nil)
        }

        // Create 1000 edges in batch
        var edges: [DependencyEdge] = []
        for i in 0..<99 {
            let fromNode = DeclarationNode(declaration: declarations[i])
            let toNode = DeclarationNode(declaration: declarations[i + 1])
            edges.append(DependencyEdge(from: fromNode.id, to: toNode.id, kind: .call))

            // Add some cross-edges for complexity
            if i > 10 {
                let crossNode = DeclarationNode(declaration: declarations[i - 10])
                edges.append(DependencyEdge(from: fromNode.id, to: crossNode.id, kind: .typeReference))
            }
        }

        // Batch insert all edges at once
        await graph.addEdges(edges)

        // Verify all edges were inserted
        let edgeCount = await graph.edgeCount
        #expect(edgeCount == edges.count)

        // Verify reachability from root
        let lastDecl = declarations[99]
        let isReachable = await graph.isReachable(lastDecl)
        #expect(isReachable == true)
    }

    // MARK: - Helper Methods

    /// Create a large analysis result for stress testing
    private func createLargeAnalysisResult(declarationCount: Int) -> AnalysisResult {
        var declarations: [Declaration] = []

        for i in 0..<declarationCount {
            let isPublic = i % 50 == 0  // Every 50th is public (root)
            let decl = Declaration(
                name: "Declaration\(i)",
                kind: i % 3 == 0 ? .class : (i % 3 == 1 ? .function : .variable),
                accessLevel: isPublic ? .public : .internal,
                modifiers: [],
                location: SourceLocation(file: "test.swift", line: i + 1, column: 1),
                range: SourceRange(
                    start: SourceLocation(file: "test.swift", line: i + 1, column: 1),
                    end: SourceLocation(file: "test.swift", line: i + 5, column: 1)
                ),
                scope: .global,
                // Create type references to create edges
                typeAnnotation: i > 0 && i % 5 == 0 ? "Declaration\(i - 1)" : nil
            )
            declarations.append(decl)
        }

        var declIndex = DeclarationIndex()
        for decl in declarations {
            declIndex.add(decl)
        }

        return AnalysisResult(
            files: ["test.swift"],
            declarations: declIndex,
            references: ReferenceIndex(),
            scopes: ScopeTree(),
            statistics: AnalysisStatistics(
                fileCount: 1,
                totalLines: declarationCount * 5,
                declarationCount: declarationCount,
                referenceCount: 0,
                declarationsByKind: [:],
                analysisTime: 0
            )
        )
    }
}
