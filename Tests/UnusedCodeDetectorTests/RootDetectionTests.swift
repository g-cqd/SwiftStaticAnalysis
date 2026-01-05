//  RootDetectionTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Root Detection Tests")
struct RootDetectionTests {
    @Test("Public declarations are roots by default")
    func publicAsRoot() async {
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

        await graph.detectRoots(declarations: declarations, references: references)

        let roots = await graph.rootNodes
        #expect(roots.count == 1)
        #expect(roots.first?.rootReason == .publicAPI)
    }

    @Test("Test methods are roots")
    func methodsAsRoots() async {
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

        await graph.detectRoots(declarations: declarations, references: references)

        let roots = await graph.rootNodes
        #expect(roots.count == 1)
        #expect(roots.first?.rootReason == .testMethod)
    }

    @Test("Main function is root")
    func mainFunctionAsRoot() async {
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

        await graph.detectRoots(declarations: declarations, references: references)

        let roots = await graph.rootNodes
        #expect(roots.count == 1)
        #expect(roots.first?.rootReason == .mainFunction)
    }

    @Test("Strict mode excludes public API")
    func strictModeExcludesPublic() async {
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
        await graph.detectRoots(declarations: declarations, references: references, configuration: strictConfig)

        let roots = await graph.rootNodes
        #expect(roots.isEmpty)
    }
}
