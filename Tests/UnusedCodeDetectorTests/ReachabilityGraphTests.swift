//  ReachabilityGraphTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Reachability Graph Tests")
struct ReachabilityGraphTests {
    @Test("Empty graph has no reachable nodes")
    func emptyGraph() async {
        let graph = ReachabilityGraph()
        let reachable = await graph.computeReachable()
        #expect(reachable.isEmpty)
    }

    @Test("Root nodes are reachable")
    func rootNodesReachable() async {
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
            scope: .global
        )

        let node = await graph.addNode(decl, isRoot: true, rootReason: .mainFunction)

        let reachable = await graph.computeReachable()
        #expect(reachable.contains(node.id))
        #expect(reachable.count == 1)
    }

    @Test("Edges make targets reachable")
    func edgeReachability() async {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(
            name: "main",
            kind: .function,
            location: location,
            range: range,
            scope: .global
        )

        let helperDecl = Declaration(
            name: "helper",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global
        )

        let mainNode = await graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let helperNode = await graph.addNode(helperDecl)

        await graph.addEdge(from: mainNode.id, to: helperNode.id, kind: .call)

        let reachable = await graph.computeReachable()
        #expect(reachable.contains(mainNode.id))
        #expect(reachable.contains(helperNode.id))
    }

    @Test("Unreachable nodes are detected")
    func unreachableNodes() async {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(
            name: "main",
            kind: .function,
            location: location,
            range: range,
            scope: .global
        )

        let unusedDecl = Declaration(
            name: "unused",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global
        )

        await graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        await graph.addNode(unusedDecl)

        let unreachable = await graph.computeUnreachable()
        #expect(unreachable.count == 1)
        #expect(unreachable.first?.declaration.name == "unused")
    }

    @Test("Transitive reachability works")
    func transitiveReachability() async {
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
            scope: .global
        )
        let utilityDecl = Declaration(
            name: "utility",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200),
            range: range,
            scope: .global
        )

        let mainNode = await graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let helperNode = await graph.addNode(helperDecl)
        let utilityNode = await graph.addNode(utilityDecl)

        await graph.addEdge(from: mainNode.id, to: helperNode.id, kind: .call)
        await graph.addEdge(from: helperNode.id, to: utilityNode.id, kind: .call)

        let reachable = await graph.computeReachable()
        #expect(reachable.count == 3)
        #expect(reachable.contains(utilityNode.id))
    }

    @Test("Path finding from root")
    func pathFinding() async {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(name: "main", kind: .function, location: location, range: range, scope: .global)
        let helperDecl = Declaration(
            name: "helper",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global
        )

        let mainNode = await graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let helperNode = await graph.addNode(helperDecl)

        await graph.addEdge(from: mainNode.id, to: helperNode.id, kind: .call)

        let path = await graph.findPathFromRoot(to: helperNode.id)
        #expect(path != nil)
        #expect(path?.count == 2)
        #expect(path?.first == mainNode.id)
        #expect(path?.last == helperNode.id)
    }

    @Test("Unreachable node has no path")
    func noPathForUnreachable() async {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(name: "main", kind: .function, location: location, range: range, scope: .global)
        let unusedDecl = Declaration(
            name: "unused",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global
        )

        await graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let unusedNode = await graph.addNode(unusedDecl)

        let path = await graph.findPathFromRoot(to: unusedNode.id)
        #expect(path == nil)
    }
}
