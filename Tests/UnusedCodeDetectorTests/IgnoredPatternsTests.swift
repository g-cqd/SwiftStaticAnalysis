//  IgnoredPatternsTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Ignored Patterns Tests")
struct IgnoredPatternsTests {
    @Test("Ignored patterns exclude matching declarations")
    func ignoredPatternsExcludeMatches() async throws {
        let source = """
            func ignoredHelper() {}
            func reportedHelper() {}
            """

        var config = UnusedCodeConfiguration.default
        config.ignorePublicAPI = false
        config.ignoredPatterns = ["^ignored"]

        let detector = UnusedCodeDetector(configuration: config)
        let unused = try await detector.detectFromSource(source, file: "IgnoredPatterns.swift")
        let names = Set(unused.map(\.declaration.name))

        #expect(names.contains("reportedHelper") == true)
        #expect(names.contains("ignoredHelper") == false)
    }

    @Test("Invalid ignored pattern does not exclude declarations")
    func invalidIgnoredPatternDoesNotExclude() async throws {
        let source = """
            func shouldReport() {}
            """

        var config = UnusedCodeConfiguration.default
        config.ignorePublicAPI = false
        config.ignoredPatterns = ["[invalid"]

        let detector = UnusedCodeDetector(configuration: config)
        let unused = try await detector.detectFromSource(source, file: "InvalidPattern.swift")
        let names = Set(unused.map(\.declaration.name))

        #expect(names.contains("shouldReport") == true)
    }
}
