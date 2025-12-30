//
//  RootDetectionTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify automatic root detection for various declaration types
//  - Test strict mode behavior
//
//  ## Coverage
//  - Public declarations are roots by default
//  - Test methods are roots
//  - Main function is root
//  - Strict mode excludes public API
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

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
            scope: .global,
        )

        let declarations = [publicDecl]
        let references = ReferenceIndex()

        graph.detectRoots(declarations: declarations, references: references)

        let roots = graph.rootNodes
        #expect(roots.count == 1)
        #expect(roots.first?.rootReason == .publicAPI)
    }

    @Test("Test methods are roots")
    func methodsAsRoots() {
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
            scope: .global,
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
            scope: .global,
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
            scope: .global,
        )

        let declarations = [publicDecl]
        let references = ReferenceIndex()

        let strictConfig = RootDetectionConfiguration.strict
        graph.detectRoots(declarations: declarations, references: references, configuration: strictConfig)

        let roots = graph.rootNodes
        #expect(roots.isEmpty)
    }
}
