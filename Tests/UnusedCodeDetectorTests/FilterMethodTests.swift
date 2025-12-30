//
//  FilterMethodTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify filter() method correctly applies all configured rules
//  - Test Array extension methods
//  - Test integration scenarios
//
//  ## Coverage
//  - filter(): excluded items, empty input, no exclusions, all matching
//  - Array extension: filtered(with:), filteredWithSensibleDefaults()
//  - Integration: production filtering, complex scenarios, invalid regex
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

// MARK: - FilterMethodTests

@Suite("Filter Method Tests")
struct FilterMethodTests {
    @Test("Filters out excluded items")
    func filtersExcludedItems() {
        let config = UnusedCodeFilterConfiguration(
            excludeImports: true,
            excludeTestSuites: true,
        )
        let filter = UnusedCodeFilter(configuration: config)

        let items = [
            makeUnusedCode(name: "Foundation", kind: .import),
            makeUnusedCode(name: "myFunction"),
            makeUnusedCode(name: "MyTests", kind: .struct),
            makeUnusedCode(name: "helper"),
        ]

        let filtered = filter.filter(items)

        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.declaration.name == "myFunction" || $0.declaration.name == "helper" })
    }

    @Test("Returns empty array for empty input")
    func handlesEmptyInput() {
        let filter = UnusedCodeFilter(configuration: .sensibleDefaults)
        let filtered = filter.filter([])
        #expect(filtered.isEmpty)
    }

    @Test("Returns all items when no exclusions configured")
    func returnsAllWhenNoExclusions() {
        let filter = UnusedCodeFilter(configuration: .none)

        let items = [
            makeUnusedCode(name: "Foundation", kind: .import),
            makeUnusedCode(name: "myFunction"),
            makeUnusedCode(name: "deinit"),
        ]

        let filtered = filter.filter(items)
        #expect(filtered.count == 3)
    }

    @Test("Filters all items when all match exclusion")
    func filtersAllMatchingItems() {
        let config = UnusedCodeFilterConfiguration(excludeImports: true)
        let filter = UnusedCodeFilter(configuration: config)

        let items = [
            makeUnusedCode(name: "Foundation", kind: .import),
            makeUnusedCode(name: "UIKit", kind: .import),
        ]

        let filtered = filter.filter(items)
        #expect(filtered.isEmpty)
    }
}

// MARK: - ArrayExtensionTests

@Suite("Array Extension Tests")
struct ArrayExtensionTests {
    @Test("Filtered with configuration works")
    func filteredWithConfiguration() {
        let config = UnusedCodeFilterConfiguration(excludeImports: true)

        let items = [
            makeUnusedCode(name: "Foundation", kind: .import),
            makeUnusedCode(name: "myFunction"),
        ]

        let filtered = items.filtered(with: config)
        #expect(filtered.count == 1)
        #expect(filtered.first?.declaration.name == "myFunction")
    }

    @Test("Filtered with sensible defaults works")
    func filteredWithSensibleDefaults() {
        let items = [
            makeUnusedCode(name: "Foundation", kind: .import),
            makeUnusedCode(name: "deinit"),
            makeUnusedCode(name: "`class`", kind: .enumCase),
            makeUnusedCode(name: "MyTests", kind: .struct),
            makeUnusedCode(name: "realFunction"),
        ]

        let filtered = items.filteredWithSensibleDefaults()
        #expect(filtered.count == 1)
        #expect(filtered.first?.declaration.name == "realFunction")
    }
}

// MARK: - FilterIntegrationTests

@Suite("Filter Integration Tests")
struct FilterIntegrationTests {
    @Test("Production configuration filters test fixtures")
    func productionFiltersFixtures() {
        let config = UnusedCodeFilterConfiguration.production()
        let filter = UnusedCodeFilter(configuration: config)

        let items = [
            makeUnusedCode(name: "unused", file: "/project/Tests/Fixtures/Sample.swift"),
            makeUnusedCode(name: "helper", file: "/project/Tests/SomeTests.swift"),
            makeUnusedCode(name: "main", file: "/project/Sources/Main.swift"),
        ]

        let filtered = filter.filter(items)
        #expect(filtered.count == 1)
        #expect(filtered.first?.declaration.name == "main")
    }

    @Test("Complex filtering scenario")
    func complexFilteringScenario() {
        let config = UnusedCodeFilterConfiguration(
            excludeImports: true,
            excludeDeinit: true,
            excludeBacktickedEnumCases: true,
            excludeTestSuites: true,
            excludePathPatterns: ["**/Fixtures/**"],
            excludeNamePatterns: ["^_.*"], // Exclude names starting with underscore
        )
        let filter = UnusedCodeFilter(configuration: config)

        let items = [
            makeUnusedCode(name: "Foundation", kind: .import), // excluded: import
            makeUnusedCode(name: "deinit"), // excluded: deinit
            makeUnusedCode(name: "`class`", kind: .enumCase), // excluded: backticked
            makeUnusedCode(name: "MyClassTests", kind: .struct), // excluded: test suite
            makeUnusedCode(name: "fixture", file: "/project/Fixtures/F.swift"), // excluded: path
            makeUnusedCode(name: "_privateHelper"), // excluded: name pattern
            makeUnusedCode(name: "validFunction"), // KEPT
            makeUnusedCode(name: "ValidClass", kind: .class), // KEPT
        ]

        let filtered = filter.filter(items)
        #expect(filtered.count == 2)

        let names = Set(filtered.map(\.declaration.name))
        #expect(names.contains("validFunction"))
        #expect(names.contains("ValidClass"))
    }

    @Test("Invalid regex pattern is ignored")
    func invalidRegexIgnored() {
        // Invalid regex pattern with unbalanced brackets
        let config = UnusedCodeFilterConfiguration(excludeNamePatterns: ["[invalid"])
        let filter = UnusedCodeFilter(configuration: config)

        // Should not crash and should not exclude anything
        let items = [makeUnusedCode(name: "myFunction")]
        let filtered = filter.filter(items)
        #expect(filtered.count == 1)
    }
}
