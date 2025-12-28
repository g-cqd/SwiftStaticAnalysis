//
//  ReachabilityTests.swift
//  SwiftStaticAnalysis
//
//  Tests for reachability graph analysis.
//

import Testing
import Foundation
@testable import UnusedCodeDetector
@testable import SwiftStaticAnalysisCore

// MARK: - Reachability Graph Tests

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
            scope: .global
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
            scope: .global
        )

        let helperDecl = Declaration(
            name: "helper",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global
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
            scope: .global
        )

        let unusedDecl = Declaration(
            name: "unused",
            kind: .function,
            location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100),
            range: range,
            scope: .global
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
        let helperDecl = Declaration(name: "helper", kind: .function, location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100), range: range, scope: .global)
        let utilityDecl = Declaration(name: "utility", kind: .function, location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200), range: range, scope: .global)

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
        let helperDecl = Declaration(name: "helper", kind: .function, location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100), range: range, scope: .global)

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
        let unusedDecl = Declaration(name: "unused", kind: .function, location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100), range: range, scope: .global)

        graph.addNode(mainDecl, isRoot: true, rootReason: .mainFunction)
        let unusedNode = graph.addNode(unusedDecl)

        let path = graph.findPathFromRoot(to: unusedNode.id)
        #expect(path == nil)
    }
}

// MARK: - Root Detection Tests

@Suite("Root Detection Tests")
struct RootDetectionTests {

    @Test("Public declarations are roots by default")
    func publicAsRoot() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let publicDecl = Declaration(
            name: "publicFunction",
            kind: .function,
            accessLevel: .public,
            modifiers: [],
            location: location,
            range: range,
            scope: .global
        )

        let declarations = [publicDecl]
        let references = ReferenceIndex()

        graph.detectRoots(declarations: declarations, references: references)

        let roots = graph.rootNodes
        #expect(roots.count == 1)
        #expect(roots.first?.rootReason == .publicAPI)
    }

    @Test("Test methods are roots")
    func testMethodsAsRoots() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let testDecl = Declaration(
            name: "testSomething",
            kind: .function,
            accessLevel: .internal,
            modifiers: [],
            location: location,
            range: range,
            scope: .global
        )

        let declarations = [testDecl]
        let references = ReferenceIndex()

        graph.detectRoots(declarations: declarations, references: references)

        let roots = graph.rootNodes
        #expect(roots.count == 1)
        #expect(roots.first?.rootReason == .testMethod)
    }

    @Test("Main function is root")
    func mainFunctionAsRoot() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(
            name: "main",
            kind: .function,
            accessLevel: .internal,
            modifiers: [],
            location: location,
            range: range,
            scope: .global
        )

        let declarations = [mainDecl]
        let references = ReferenceIndex()

        graph.detectRoots(declarations: declarations, references: references)

        let roots = graph.rootNodes
        #expect(roots.count == 1)
        #expect(roots.first?.rootReason == .mainFunction)
    }

    @Test("Strict mode excludes public API")
    func strictModeExcludesPublic() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let publicDecl = Declaration(
            name: "publicFunction",
            kind: .function,
            accessLevel: .public,
            modifiers: [],
            location: location,
            range: range,
            scope: .global
        )

        let declarations = [publicDecl]
        let references = ReferenceIndex()

        let strictConfig = RootDetectionConfiguration.strict
        graph.detectRoots(declarations: declarations, references: references, configuration: strictConfig)

        let roots = graph.rootNodes
        #expect(roots.isEmpty)
    }
}

// MARK: - Reachability Report Tests

@Suite("Reachability Report Tests")
struct ReachabilityReportTests {

    @Test("Report contains correct counts")
    func reportCounts() {
        let graph = ReachabilityGraph()

        let location = SourceLocation(file: "test.swift", line: 1, column: 1, offset: 0)
        let range = SourceRange(start: location, end: location)

        let mainDecl = Declaration(name: "main", kind: .function, location: location, range: range, scope: .global)
        let usedDecl = Declaration(name: "used", kind: .function, location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100), range: range, scope: .global)
        let unusedDecl = Declaration(name: "unused", kind: .function, location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200), range: range, scope: .global)

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
        let decl2 = Declaration(name: "used", kind: .function, location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100), range: range, scope: .global)
        let decl3 = Declaration(name: "unused1", kind: .function, location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200), range: range, scope: .global)
        let decl4 = Declaration(name: "unused2", kind: .function, location: SourceLocation(file: "test.swift", line: 30, column: 1, offset: 300), range: range, scope: .global)

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
        let unusedFunc = Declaration(name: "unusedFunc", kind: .function, location: SourceLocation(file: "test.swift", line: 10, column: 1, offset: 100), range: range, scope: .global)
        let unusedClass = Declaration(name: "UnusedClass", kind: .class, location: SourceLocation(file: "test.swift", line: 20, column: 1, offset: 200), range: range, scope: .global)

        graph.addNode(main, isRoot: true, rootReason: .mainFunction)
        graph.addNode(unusedFunc)
        graph.addNode(unusedClass)

        let report = graph.generateReport()

        #expect(report.unreachableByKind[.function] == 1)
        #expect(report.unreachableByKind[.class] == 1)
    }
}

// MARK: - Dependency Extraction Tests

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
            treatTestsAsRoot: false
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
}

// MARK: - Reachability-Based Detector Tests

@Suite("Reachability-Based Detector Tests")
struct ReachabilityBasedDetectorTests {

    @Test("Detector initialization")
    func detectorInitialization() {
        let detector = ReachabilityBasedDetector()
        #expect(detector.configuration.mode == .simple)
    }

    @Test("Detector with reachability mode")
    func reachabilityModeConfig() {
        let config = UnusedCodeConfiguration.reachability
        #expect(config.mode == .reachability)
    }
}

// MARK: - Detection Mode Tests

@Suite("Detection Mode Tests")
struct DetectionModeTests {

    @Test("Simple mode is default")
    func defaultMode() {
        let config = UnusedCodeConfiguration()
        #expect(config.mode == .simple)
    }

    @Test("Reachability configuration preset")
    func reachabilityPreset() {
        let config = UnusedCodeConfiguration.reachability
        #expect(config.mode == .reachability)
    }

    @Test("IndexStore configuration preset")
    func indexStorePreset() {
        let config = UnusedCodeConfiguration.indexStore
        #expect(config.mode == .indexStore)
    }

    @Test("Strict configuration preset")
    func strictPreset() {
        let config = UnusedCodeConfiguration.strict
        #expect(config.mode == .reachability)
        #expect(config.ignorePublicAPI == false)
        #expect(config.treatPublicAsRoot == false)
        #expect(config.minimumConfidence == .low)
    }
}
