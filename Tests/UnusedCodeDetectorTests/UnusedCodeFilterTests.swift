//
//  UnusedCodeFilterTests.swift
//  SwiftStaticAnalysis
//
//  Tests for unused code filtering to reduce false positives.
//

import Foundation
@testable import SwiftStaticAnalysisCore
import Testing
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

// MARK: - FilterConfigurationTests

@Suite("Filter Configuration Tests")
struct FilterConfigurationTests {
    @Test("Default configuration has no exclusions")
    func defaultConfig() {
        let config = UnusedCodeFilterConfiguration()
        #expect(config.excludeImports == false)
        #expect(config.excludeDeinit == false)
        #expect(config.excludeBacktickedEnumCases == false)
        #expect(config.excludeTestSuites == false)
        #expect(config.excludePathPatterns.isEmpty)
        #expect(config.excludeNamePatterns.isEmpty)
    }

    @Test("None preset matches default")
    func nonePreset() {
        let config = UnusedCodeFilterConfiguration.none
        #expect(config.excludeImports == false)
        #expect(config.excludeDeinit == false)
        #expect(config.excludeBacktickedEnumCases == false)
        #expect(config.excludeTestSuites == false)
    }

    @Test("Sensible defaults preset enables common exclusions")
    func sensibleDefaultsPreset() {
        let config = UnusedCodeFilterConfiguration.sensibleDefaults
        #expect(config.excludeImports == true)
        #expect(config.excludeDeinit == true)
        #expect(config.excludeBacktickedEnumCases == true)
        #expect(config.excludeTestSuites == true)
    }

    @Test("Production preset excludes test paths")
    func productionPreset() {
        let config = UnusedCodeFilterConfiguration.production()
        #expect(config.excludeImports == true)
        #expect(config.excludePathPatterns.contains("**/Tests/**"))
        #expect(config.excludePathPatterns.contains("**/*Tests.swift"))
        #expect(config.excludePathPatterns.contains("**/Fixtures/**"))
    }

    @Test("Production preset without test path exclusion")
    func productionPresetNoTestExclusion() {
        let config = UnusedCodeFilterConfiguration.production(excludeTestPaths: false)
        #expect(config.excludeImports == true)
        #expect(config.excludePathPatterns.isEmpty)
    }
}

// MARK: - BacktickedIdentifierTests

@Suite("Backticked Identifier Detection Tests")
struct BacktickedIdentifierTests {
    @Test("Detects backticked identifier")
    func detectsBackticked() {
        #expect(UnusedCodeFilter.isBacktickedIdentifier("`class`") == true)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("`protocol`") == true)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("`default`") == true)
    }

    @Test("Rejects non-backticked identifier")
    func rejectsNonBackticked() {
        #expect(UnusedCodeFilter.isBacktickedIdentifier("class") == false)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("MyClass") == false)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("") == false)
    }

    @Test("Rejects partial backticks")
    func rejectsPartialBackticks() {
        #expect(UnusedCodeFilter.isBacktickedIdentifier("`class") == false)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("class`") == false)
    }
}

// MARK: - TestSuiteNameTests

@Suite("Test Suite Name Detection Tests")
struct TestSuiteNameTests {
    @Test("Detects test suite names ending with Tests")
    func detectsTestsEnding() {
        #expect(UnusedCodeFilter.isTestSuiteName("MyClassTests") == true)
        #expect(UnusedCodeFilter.isTestSuiteName("FilterTests") == true)
        #expect(UnusedCodeFilter.isTestSuiteName("IntegrationTests") == true)
    }

    @Test("Detects test suite names ending with Test")
    func detectsTestEnding() {
        #expect(UnusedCodeFilter.isTestSuiteName("MyClassTest") == true)
        #expect(UnusedCodeFilter.isTestSuiteName("UnitTest") == true)
    }

    @Test("Rejects non-test names")
    func rejectsNonTest() {
        #expect(UnusedCodeFilter.isTestSuiteName("MyClass") == false)
        #expect(UnusedCodeFilter.isTestSuiteName("Testing") == false)
        #expect(UnusedCodeFilter.isTestSuiteName("TestHelper") == false)
        #expect(UnusedCodeFilter.isTestSuiteName("") == false)
    }
}

// MARK: - GlobPatternMatchingTests

@Suite("Glob Pattern Matching Tests")
struct GlobPatternMatchingTests {
    @Test("Matches single star wildcard")
    func matchesSingleStar() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "/src/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/test.swift", pattern: "/src/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/sub/file.swift", pattern: "/src/*.swift") == false)
    }

    @Test("Matches double star wildcard")
    func matchesDoubleStar() {
        // ** matches zero or more path segments
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/deep/nested/file.swift", pattern: "/src/**/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/sub/file.swift", pattern: "/src/**/*.swift") == true)
        // Note: /src/**/*.swift requires at least one directory segment due to the / after **
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "/src/**/*.swift") == false)
        #expect(UnusedCodeFilter.matchesGlobPattern("/other/file.swift", pattern: "/src/**/*.swift") == false)
        // Pattern without trailing /* matches files directly too
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "/src/**.swift") == true)
    }

    @Test("Matches Tests directory pattern")
    func matchesTestsPattern() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/project/Tests/MyTests.swift", pattern: "**/Tests/**") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/Tests/file.swift", pattern: "**/Tests/**") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/Tests/nested/file.swift", pattern: "**/Tests/**") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "**/Tests/**") == false)
    }

    @Test("Matches Fixtures directory pattern")
    func matchesFixturesPattern() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/project/Fixtures/test.swift", pattern: "**/Fixtures/**") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/Tests/Fixtures/sample.swift", pattern: "**/Fixtures/**") == true)
    }

    @Test("Matches file suffix pattern")
    func matchesFileSuffix() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/MyClassTests.swift", pattern: "**/*Tests.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/deep/HelperTests.swift", pattern: "**/*Tests.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/MyClass.swift", pattern: "**/*Tests.swift") == false)
    }

    @Test("Escapes dots in patterns")
    func escapesDotsInPatterns() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/fileXswift", pattern: "*.swift") == false)
    }

    @Test("Handles question mark wildcard")
    func handlesQuestionMark() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file1.swift", pattern: "/src/file?.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/fileA.swift", pattern: "/src/file?.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file12.swift", pattern: "/src/file?.swift") == false)
    }
}

// MARK: - ShouldExcludeTests

@Suite("Should Exclude Tests")
struct ShouldExcludeTests {
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
