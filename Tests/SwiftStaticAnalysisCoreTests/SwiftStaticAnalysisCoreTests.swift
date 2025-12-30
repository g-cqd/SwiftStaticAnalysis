//
//  SwiftStaticAnalysisCoreTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify core model types initialize correctly (SourceLocation, SourceRange, Scope)
//  - Test ScopeTree add/retrieve operations
//  - Validate DeclarationKind and AccessLevel enums
//  - Test DeclarationIndex and ReferenceIndex operations
//
//  ## Coverage
//  - SourceLocation: initialization, description format
//  - SourceRange: line count calculation
//  - ScopeID: equality comparison
//  - ScopeTree: add and retrieve scopes
//  - DeclarationKind: raw values
//  - AccessLevel: comparison operators
//  - DeclarationIndex: add, find by name/kind/file
//  - ReferenceIndex: add, find by identifier/context
//

import Testing

@testable import SwiftStaticAnalysisCore

@Suite("SwiftStaticAnalysisCore Tests")
struct SwiftStaticAnalysisCoreTests {
    @Test("SourceLocation initialization")
    func sourceLocationInit() {
        let location = SourceLocation(file: "test.swift", line: 10, column: 5, offset: 100)

        #expect(location.file == "test.swift")
        #expect(location.line == 10)
        #expect(location.column == 5)
        #expect(location.offset == 100)
    }

    @Test("SourceLocation description")
    func sourceLocationDescription() {
        let location = SourceLocation(file: "test.swift", line: 10, column: 5)

        #expect(location.description == "test.swift:10:5")
    }

    @Test("SourceRange line count")
    func sourceRangeLineCount() {
        let start = SourceLocation(file: "test.swift", line: 10, column: 1)
        let end = SourceLocation(file: "test.swift", line: 15, column: 10)
        let range = SourceRange(start: start, end: end)

        #expect(range.lineCount == 6)
    }

    @Test("ScopeID equality")
    func scopeIdEquality() {
        let scope1 = ScopeID("test:1")
        let scope2 = ScopeID("test:1")
        let scope3 = ScopeID("test:2")

        #expect(scope1 == scope2)
        #expect(scope1 != scope3)
    }

    @Test("ScopeTree add and retrieve")
    func scopeTreeAddRetrieve() {
        var tree = ScopeTree()

        let globalScope = Scope(
            id: .global,
            kind: .global,
            location: SourceLocation(file: "test.swift", line: 1, column: 1),
        )
        tree.add(globalScope)

        let funcScope = Scope(
            id: ScopeID("test:1"),
            kind: .function,
            name: "myFunc",
            parent: .global,
            location: SourceLocation(file: "test.swift", line: 5, column: 1),
        )
        tree.add(funcScope)

        #expect(tree.scope(for: .global) != nil)
        #expect(tree.scope(for: ScopeID("test:1"))?.name == "myFunc")
    }

    @Test("DeclarationKind all cases")
    func declarationKindCases() {
        #expect(!DeclarationKind.allCases.isEmpty)
        #expect(DeclarationKind.function.rawValue == "function")
        #expect(DeclarationKind.variable.rawValue == "variable")
    }

    @Test("AccessLevel comparison")
    func accessLevelComparison() {
        #expect(AccessLevel.private < AccessLevel.fileprivate)
        #expect(AccessLevel.fileprivate < AccessLevel.internal)
        #expect(AccessLevel.internal < AccessLevel.public)
        #expect(AccessLevel.public < AccessLevel.open)
    }

    @Test("DeclarationIndex add and find")
    func declarationIndexOperations() {
        var index = DeclarationIndex()

        let decl = Declaration(
            name: "myFunction",
            kind: .function,
            accessLevel: .internal,
            modifiers: [],
            location: SourceLocation(file: "test.swift", line: 10, column: 1),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 10, column: 1),
                end: SourceLocation(file: "test.swift", line: 15, column: 1),
            ),
            scope: .global,
        )

        index.add(decl)

        #expect(index.find(name: "myFunction").count == 1)
        #expect(index.find(kind: .function).count == 1)
        #expect(index.find(inFile: "test.swift").count == 1)
    }

    @Test("ReferenceIndex add and find")
    func referenceIndexOperations() {
        var index = ReferenceIndex()

        let ref = Reference(
            identifier: "myVar",
            location: SourceLocation(file: "test.swift", line: 20, column: 5),
            scope: .global,
            context: .read,
        )

        index.add(ref)

        #expect(index.find(identifier: "myVar").count == 1)
        #expect(index.find(context: .read).count == 1)
        #expect(index.uniqueIdentifiers.contains("myVar"))
    }
}
