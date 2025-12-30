//
//  CloneModelTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify CloneType, Clone, CloneGroup model initialization
//  - Test CloneGroup metrics calculation
//  - Validate DuplicationConfiguration defaults
//  - Test DuplicationDetector initialization
//  - Verify DuplicationReport metrics
//
//  ## Coverage
//  - CloneType: raw values
//  - Clone: initialization, properties
//  - CloneGroup: occurrences, duplicatedLines
//  - DuplicationConfiguration: default values
//  - DuplicationDetector: initialization with configuration
//  - DuplicationReport: duplicatedLines, duplicationPercentage
//

import Testing
@testable import DuplicationDetector

@Suite("Clone Model Tests")
struct CloneModelTests {
    @Test("CloneType raw values")
    func cloneTypeRawValues() {
        #expect(CloneType.exact.rawValue == "exact")
        #expect(CloneType.near.rawValue == "near")
        #expect(CloneType.semantic.rawValue == "semantic")
    }

    @Test("Clone initialization")
    func cloneInit() {
        let clone = Clone(
            file: "test.swift",
            startLine: 10,
            endLine: 20,
            tokenCount: 50,
            codeSnippet: "func test() { }",
        )

        #expect(clone.file == "test.swift")
        #expect(clone.startLine == 10)
        #expect(clone.endLine == 20)
        #expect(clone.tokenCount == 50)
    }

    @Test("CloneGroup metrics")
    func cloneGroupMetrics() {
        let clones = [
            Clone(file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, codeSnippet: ""),
            Clone(file: "b.swift", startLine: 5, endLine: 14, tokenCount: 50, codeSnippet: ""),
        ]

        let group = CloneGroup(
            type: .exact,
            clones: clones,
            similarity: 1.0,
            fingerprint: "abc123",
        )

        #expect(group.occurrences == 2)
        #expect(group.duplicatedLines == 20) // 10 + 10
    }

    @Test("DuplicationConfiguration defaults")
    func configurationDefaults() {
        let config = DuplicationConfiguration.default

        #expect(config.minimumTokens == 50)
        #expect(config.cloneTypes == [.exact])
        #expect(config.minimumSimilarity == 0.8)
    }

    @Test("DuplicationDetector initialization")
    func detectorInit() {
        let config = DuplicationConfiguration(
            minimumTokens: 30,
            cloneTypes: [.exact, .near],
        )

        let detector = DuplicationDetector(configuration: config)

        #expect(detector.configuration.minimumTokens == 30)
        #expect(detector.configuration.cloneTypes.contains(.exact))
        #expect(detector.configuration.cloneTypes.contains(.near))
    }

    @Test("DuplicationReport metrics")
    func reportMetrics() {
        let clones = [
            Clone(file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, codeSnippet: ""),
            Clone(file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, codeSnippet: ""),
        ]

        let group = CloneGroup(type: .exact, clones: clones, similarity: 1.0, fingerprint: "x")

        let report = DuplicationReport(
            filesAnalyzed: 10,
            totalLines: 1000,
            cloneGroups: [group],
        )

        #expect(report.duplicatedLines == 20)
        #expect(report.duplicationPercentage == 2.0)
    }
}
