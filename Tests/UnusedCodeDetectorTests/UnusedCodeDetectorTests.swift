//
//  UnusedCodeDetectorTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify UnusedCodeDetector and related model types initialize correctly
//  - Test UnusedReason and Confidence enums
//  - Validate UnusedCode model behavior
//  - Test UnusedCodeConfiguration defaults and presets
//  - Verify UnusedCodeReport summary calculations
//
//  ## Coverage
//  - UnusedReason: raw values
//  - Confidence: comparison operators
//  - UnusedCode: initialization with declaration, reason, confidence
//  - UnusedCodeConfiguration: defaults, detectVariables/Functions/Types/Imports
//  - UnusedCodeDetector: initialization with configuration
//  - UnusedCodeReport: summaryByKind, summaryByConfidence
//

import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("UnusedCodeDetector Tests")
struct UnusedCodeDetectorTests {
    @Test("UnusedReason raw values")
    func unusedReasonRawValues() {
        #expect(UnusedReason.neverReferenced.rawValue == "neverReferenced")
        #expect(UnusedReason.onlyAssigned.rawValue == "onlyAssigned")
        #expect(UnusedReason.importNotUsed.rawValue == "importNotUsed")
    }

    @Test("Confidence comparison")
    func confidenceComparison() {
        #expect(Confidence.low < Confidence.medium)
        #expect(Confidence.medium < Confidence.high)
    }

    @Test("UnusedCode initialization")
    func unusedCodeInit() {
        let decl = Declaration(
            name: "unusedVar",
            kind: .variable,
            accessLevel: .private,
            modifiers: [],
            location: SourceLocation(file: "test.swift", line: 10, column: 5),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 10, column: 5),
                end: SourceLocation(file: "test.swift", line: 10, column: 20),
            ),
            scope: .global,
        )

        let unused = UnusedCode(
            declaration: decl,
            reason: .neverReferenced,
            confidence: .high,
        )

        #expect(unused.declaration.name == "unusedVar")
        #expect(unused.reason == .neverReferenced)
        #expect(unused.confidence == .high)
    }

    @Test("UnusedCodeConfiguration defaults")
    func configurationDefaults() {
        let config = UnusedCodeConfiguration.default

        #expect(config.detectVariables == true)
        #expect(config.detectFunctions == true)
        #expect(config.detectTypes == true)
        #expect(config.detectImports == true)
        #expect(config.ignorePublicAPI == true)
        #expect(config.mode == .simple)
    }

    @Test("UnusedCodeDetector initialization")
    func detectorInit() {
        let config = UnusedCodeConfiguration(
            detectVariables: true,
            detectFunctions: false,
            ignorePublicAPI: false,
        )

        let detector = UnusedCodeDetector(configuration: config)

        #expect(detector.configuration.detectVariables == true)
        #expect(detector.configuration.detectFunctions == false)
        #expect(detector.configuration.ignorePublicAPI == false)
    }

    @Test("UnusedCodeReport summaries")
    func reportSummaries() {
        let decl1 = Declaration(
            name: "unusedVar",
            kind: .variable,
            accessLevel: .private,
            modifiers: [],
            location: SourceLocation(file: "test.swift", line: 10, column: 5),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 10, column: 5),
                end: SourceLocation(file: "test.swift", line: 10, column: 20),
            ),
            scope: .global,
        )

        let decl2 = Declaration(
            name: "unusedFunc",
            kind: .function,
            accessLevel: .internal,
            modifiers: [],
            location: SourceLocation(file: "test.swift", line: 20, column: 1),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 20, column: 1),
                end: SourceLocation(file: "test.swift", line: 25, column: 1),
            ),
            scope: .global,
        )

        let unusedItems = [
            UnusedCode(declaration: decl1, reason: .neverReferenced, confidence: .high),
            UnusedCode(declaration: decl2, reason: .neverReferenced, confidence: .medium),
        ]

        let report = UnusedCodeReport(
            filesAnalyzed: 5,
            totalDeclarations: 100,
            unusedItems: unusedItems,
        )

        #expect(report.summaryByKind["variable"] == 1)
        #expect(report.summaryByKind["function"] == 1)
        #expect(report.summaryByConfidence["high"] == 1)
        #expect(report.summaryByConfidence["medium"] == 1)
    }

    @Test("Underscore declarations are not flagged as unused")
    func underscoreDeclarationsNotFlagged() async throws {
        let source = """
            func test(_: Int) {
                print("test")
            }

            func demo() {
                let _ = someValue()
                for _ in 0..<10 {
                    print("loop")
                }
            }

            func someValue() -> Int { 42 }
            """

        let detector = UnusedCodeDetector(configuration: .default)
        let unusedItems = try await detector.detectFromSource(source, file: "test.swift")

        // No underscore declarations should be reported
        let underscoreItems = unusedItems.filter { $0.declaration.name == "_" }
        #expect(underscoreItems.isEmpty)
    }
}
