//
//  ReachabilityReportTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify report generation with correct statistics
//  - Test percentage calculation and grouping
//
//  ## Coverage
//  - Report contains correct counts (total, root, reachable, unreachable)
//  - Reachability percentage calculation
//  - Grouping unreachable by kind
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Reachability Report Tests")
struct ReachabilityReportTests {
    @Test("Report contains correct counts")
    func reportCounts() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(name: "main", kind: .function, location: location, range: range, scope: .global)
        let usedDecl = Declaration(
            name: "used",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global,
        )
        let unusedDecl = Declaration(
            name: "unused",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200),
            range: range,
            scope: .global,
        )

        let mainNode = graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let usedNode = graph.addNode(usedDecl)
        graph.addNode(unusedDecl)

        graph.addEdge(from: mainNode.id, to: usedNode.id, kind: .call)

        let report = graph.generateReport()

        #expect(report.totalDeclarations == 3)
        #expect(report.rootCount == 1)
        #expect(report.reachableCount == 2)
        #expect(report.unreachableCount == 1)
    }

    @Test("Report calculates reachability percentage")
    func reachabilityPercentage() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        // 2 reachable out of 4 = 50%
        let decl1 = Declaration(name: "root", kind: .function, location: location, range: range, scope: .global)
        let decl2 = Declaration(
            name: "used",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global,
        )
        let decl3 = Declaration(
            name: "unused1",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200),
            range: range,
            scope: .global,
        )
        let decl4 = Declaration(
            name: "unused2",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 30, column: 1, offset: 300),
            range: range,
            scope: .global,
        )

        let rootNode = graph.addNode(decl1, isRoot: true, rootReason: .mainFunction)
        let usedNode = graph.addNode(decl2)
        graph.addNode(decl3)
        graph.addNode(decl4)

        graph.addEdge(from: rootNode.id, to: usedNode.id, kind: .call)

        let report = graph.generateReport()

        #expect(report.reachabilityPercentage == 50.0)
    }

    @Test("Report groups unreachable by kind")
    func unreachableByKind() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let main = Declaration(name: "main", kind: .function, location: location, range: range, scope: .global)
        let unusedFunc = Declaration(
            name: "unusedFunc",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global,
        )
        let unusedClass = Declaration(
            name: "UnusedClass",
            kind: .class,
            location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200),
            range: range,
            scope: .global,
        )

        graph.addNode(main, isRoot: true, rootReason: .mainFunction)
        graph.addNode(unusedFunc)
        graph.addNode(unusedClass)

        let report = graph.generateReport()

        #expect(report.unreachableByKind[.function] == 1)
        #expect(report.unreachableByKind[.class] == 1)
    }
}
