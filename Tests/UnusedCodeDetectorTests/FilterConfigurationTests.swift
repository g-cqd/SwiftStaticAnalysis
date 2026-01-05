//  FilterConfigurationTests.swift
//  SwiftStaticAnalysis
//  MIT License

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
