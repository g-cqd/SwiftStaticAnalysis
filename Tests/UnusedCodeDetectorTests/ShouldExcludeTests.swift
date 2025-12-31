//
//  ShouldExcludeTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify shouldExclude() method for individual rules
//
//  ## Coverage
//  - Excludes imports when configured
//  - Excludes deinit when configured
//  - Excludes backticked enum cases when configured
//  - Excludes test suites when configured
//  - Excludes by path pattern
//  - Excludes by name pattern (regex)
//  - Applies multiple exclusion rules
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

// MARK: - Helper Functions

private func makeDeclaration(
    name: String,
    kind: DeclarationKind = .function,
    file: String = "test.swift",
    line: Int = 1,
) -> Declaration {
    let location = SourceLocation(file: file, line: line, column: 1, offset: 0)
    let range = SourceRange(start: location, end: location)
    return Declaration(
        name: name,
        kind: kind,
        accessLevel: .internal,
        modifiers: [],
        location: location,
        range: range,
        scope: .global,
    )
}

private func makeUnusedCode(
    name: String,
    kind: DeclarationKind = .function,
    file: String = "test.swift",
    line: Int = 1,
) -> UnusedCode {
    let decl = makeDeclaration(name: name, kind: kind, file: file, line: line)
    return UnusedCode(
        declaration: decl,
        reason: .neverReferenced,
        confidence: .medium,
    )
}

// MARK: - ShouldExcludeTests

@Suite("Should Exclude Tests")
struct ShouldExcludeTests {
    @Test("Always excludes underscore identifier regardless of configuration")
    func alwaysExcludesUnderscore() {
        // Underscore is Swift's "discard this value" identifier - should always be excluded
        let filter = UnusedCodeFilter(configuration: .none)

        let underscoreVar = makeUnusedCode(name: "_", kind: .variable)
        #expect(filter.shouldExclude(underscoreVar) == true)

        let underscoreParam = makeUnusedCode(name: "_", kind: .parameter)
        #expect(filter.shouldExclude(underscoreParam) == true)

        // Normal identifiers should not be excluded with .none config
        let normalVar = makeUnusedCode(name: "value", kind: .variable)
        #expect(filter.shouldExclude(normalVar) == false)
    }

    @Test("Does not exclude identifiers that merely contain underscores")
    func doesNotExcludePartialUnderscoreNames() {
        let filter = UnusedCodeFilter(configuration: .none)

        // Leading underscore (private convention)
        let leadingUnderscore = makeUnusedCode(name: "_privateVar", kind: .variable)
        #expect(filter.shouldExclude(leadingUnderscore) == false)

        // Trailing underscore
        let trailingUnderscore = makeUnusedCode(name: "value_", kind: .variable)
        #expect(filter.shouldExclude(trailingUnderscore) == false)

        // Double underscore (valid Swift identifier)
        let doubleUnderscore = makeUnusedCode(name: "__", kind: .variable)
        #expect(filter.shouldExclude(doubleUnderscore) == false)

        // Snake case
        let snakeCase = makeUnusedCode(name: "my_variable", kind: .variable)
        #expect(filter.shouldExclude(snakeCase) == false)
    }

    @Test("Excludes imports when configured")
    func excludesImports() {
        let config = UnusedCodeFilterConfiguration(excludeImports: true)
        let filter = UnusedCodeFilter(configuration: config)

        let importItem = makeUnusedCode(name: "Foundation", kind: .import)
        #expect(filter.shouldExclude(importItem) == true)

        let functionItem = makeUnusedCode(name: "myFunction", kind: .function)
        #expect(filter.shouldExclude(functionItem) == false)
    }

    @Test("Does not exclude imports when not configured")
    func doesNotExcludeImportsWhenDisabled() {
        let config = UnusedCodeFilterConfiguration(excludeImports: false)
        let filter = UnusedCodeFilter(configuration: config)

        let importItem = makeUnusedCode(name: "Foundation", kind: .import)
        #expect(filter.shouldExclude(importItem) == false)
    }

    @Test("Excludes deinit when configured")
    func excludesDeinit() {
        let config = UnusedCodeFilterConfiguration(excludeDeinit: true)
        let filter = UnusedCodeFilter(configuration: config)

        let deinitItem = makeUnusedCode(name: "deinit", kind: .function)
        #expect(filter.shouldExclude(deinitItem) == true)

        let initItem = makeUnusedCode(name: "init", kind: .function)
        #expect(filter.shouldExclude(initItem) == false)
    }

    @Test("Excludes backticked enum cases when configured")
    func excludesBacktickedEnumCases() {
        let config = UnusedCodeFilterConfiguration(excludeBacktickedEnumCases: true)
        let filter = UnusedCodeFilter(configuration: config)

        let backtickedItem = makeUnusedCode(name: "`class`", kind: .enumCase)
        #expect(filter.shouldExclude(backtickedItem) == true)

        let normalItem = makeUnusedCode(name: "myCase", kind: .enumCase)
        #expect(filter.shouldExclude(normalItem) == false)
    }

    @Test("Excludes test suites when configured")
    func excludesTestSuites() {
        let config = UnusedCodeFilterConfiguration(excludeTestSuites: true)
        let filter = UnusedCodeFilter(configuration: config)

        let testSuiteItem = makeUnusedCode(name: "MyClassTests", kind: .struct)
        #expect(filter.shouldExclude(testSuiteItem) == true)

        let normalItem = makeUnusedCode(name: "MyClass", kind: .struct)
        #expect(filter.shouldExclude(normalItem) == false)
    }

    @Test("Excludes by path pattern")
    func excludesByPathPattern() {
        let config = UnusedCodeFilterConfiguration(excludePathPatterns: ["**/Tests/**", "**/Fixtures/**"])
        let filter = UnusedCodeFilter(configuration: config)

        let testItem = makeUnusedCode(name: "helper", file: "/project/Tests/Helper.swift")
        #expect(filter.shouldExclude(testItem) == true)

        let fixtureItem = makeUnusedCode(name: "sample", file: "/project/Fixtures/Sample.swift")
        #expect(filter.shouldExclude(fixtureItem) == true)

        let srcItem = makeUnusedCode(name: "main", file: "/project/Sources/Main.swift")
        #expect(filter.shouldExclude(srcItem) == false)
    }

    @Test("Excludes by name pattern (regex)")
    func excludesByNamePattern() {
        let config = UnusedCodeFilterConfiguration(excludeNamePatterns: ["^test.*", ".*Helper$"])
        let filter = UnusedCodeFilter(configuration: config)

        let testPrefixItem = makeUnusedCode(name: "testSomething")
        #expect(filter.shouldExclude(testPrefixItem) == true)

        let helperSuffixItem = makeUnusedCode(name: "MyHelper")
        #expect(filter.shouldExclude(helperSuffixItem) == true)

        let normalItem = makeUnusedCode(name: "myFunction")
        #expect(filter.shouldExclude(normalItem) == false)
    }

    @Test("Applies multiple exclusion rules")
    func appliesMultipleRules() {
        let config = UnusedCodeFilterConfiguration(
            excludeImports: true,
            excludeDeinit: true,
            excludeTestSuites: true,
        )
        let filter = UnusedCodeFilter(configuration: config)

        let importItem = makeUnusedCode(name: "Foundation", kind: .import)
        #expect(filter.shouldExclude(importItem) == true)

        let deinitItem = makeUnusedCode(name: "deinit")
        #expect(filter.shouldExclude(deinitItem) == true)

        let testItem = makeUnusedCode(name: "MyTests")
        #expect(filter.shouldExclude(testItem) == true)

        let normalItem = makeUnusedCode(name: "myFunction")
        #expect(filter.shouldExclude(normalItem) == false)
    }
}
