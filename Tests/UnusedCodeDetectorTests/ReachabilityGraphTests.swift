//
//  ReachabilityGraphTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify ReachabilityGraph construction and traversal
//  - Test node addition, edge addition, reachability computation
//
//  ## Coverage
//  - Empty graph has no reachable nodes
//  - Root nodes are reachable
//  - Edges make targets reachable
//  - Unreachable nodes are detected
//  - Transitive reachability through edge chains
//  - Path finding from root to target
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Reachability Graph Tests")
struct ReachabilityGraphTests {
    @Test("Empty graph has no reachable nodes")
    func emptyGraph() {
        let graph = ReachabilityGraph()
        let reachable = graph.computeReachable()
        #expect(reachable.isEmpty)
    }

    @Test("Root nodes are reachable")
    func rootNodesReachable() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)
        let decl = Declaration(
            name: "main",
            kind: .function,
            accessLevel: .internal,
            modifiers: [],
            location: location,
            range: range,
            scope: .global,
        )

        let node = graph.addNode(decl, isRoot: true, rootReason: .mainFunction)

        let reachable = graph.computeReachable()
        #expect(reachable.contains(node.id))
        #expect(reachable.count == 1)
    }

    @Test("Edges make targets reachable")
    func edgeReachability() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(
            name: "main",
            kind: .function,
            location: location,
            range: range,
            scope: .global,
        )

        let helperDecl = Declaration(
            name: "helper",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global,
        )

        let mainNode = graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let helperNode = graph.addNode(helperDecl)

        graph.addEdge(from: mainNode.id, to: helperNode.id, kind: .call)

        let reachable = graph.computeReachable()
        #expect(reachable.contains(mainNode.id))
        #expect(reachable.contains(helperNode.id))
    }

    @Test("Unreachable nodes are detected")
    func unreachableNodes() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(
            name: "main",
            kind: .function,
            location: location,
            range: range,
            scope: .global,
        )

        let unusedDecl = Declaration(
            name: "unused",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global,
        )

        graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        graph.addNode(unusedDecl)

        let unreachable = graph.computeUnreachable()
        #expect(unreachable.count == 1)
        #expect(unreachable.first?.declaration.name == "unused")
    }

    @Test("Transitive reachability works")
    func transitiveReachability() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        // Create chain: main -> helper -> utility
        let mainDecl = Declaration(name: "main", kind: .function, location: location, range: range, scope: .global)
        let helperDecl = Declaration(
            name: "helper",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global,
        )
        let utilityDecl = Declaration(
            name: "utility",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200),
            range: range,
            scope: .global,
        )

        let mainNode = graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let helperNode = graph.addNode(helperDecl)
        let utilityNode = graph.addNode(utilityDecl)

        graph.addEdge(from: mainNode.id, to: helperNode.id, kind: .call)
        graph.addEdge(from: helperNode.id, to: utilityNode.id, kind: .call)

        let reachable = graph.computeReachable()
        #expect(reachable.count == 3)
        #expect(reachable.contains(utilityNode.id))
    }

    @Test("Path finding from root")
    func pathFinding() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(name: "main", kind: .function, location: location, range: range, scope: .global)
        let helperDecl = Declaration(
            name: "helper",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global,
        )

        let mainNode = graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let helperNode = graph.addNode(helperDecl)

        graph.addEdge(from: mainNode.id, to: helperNode.id, kind: .call)

        let path = graph.findPathFromRoot(to: helperNode.id)
        #expect(path != nil)
        #expect(path?.count == 2)
        #expect(path?.first == mainNode.id)
        #expect(path?.last == helperNode.id)
    }

    @Test("Unreachable node has no path")
    func noPathForUnreachable() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(name: "main", kind: .function, location: location, range: range, scope: .global)
        let unusedDecl = Declaration(
            name: "unused",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global,
        )

        graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let unusedNode = graph.addNode(unusedDecl)

        let path = graph.findPathFromRoot(to: unusedNode.id)
        #expect(path == nil)
    }
}
