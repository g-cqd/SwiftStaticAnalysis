//  IncrementalUnusedCodeDetectorTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Incremental Unused Code Detector Tests")
struct IncrementalUnusedCodeDetectorTests {
    @Test("Ignored patterns are applied during incremental detection")
    func ignoredPatternsAppliedIncrementally() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("Sample.swift")
        let source = """
            func ignoredFunction() {}
            func reportedFunction() {}
            """
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        var config = UnusedCodeConfiguration.incremental(cacheDirectory: tempDir)
        config.ignorePublicAPI = false
        config.ignoredPatterns = ["^ignored"]

        let detector = IncrementalUnusedCodeDetector(configuration: config)
        let result = try await detector.detectUnused(in: [sourceURL.path])
        let names = Set(result.unusedCode.map(\.declaration.name))

        #expect(names.contains("reportedFunction") == true)
        #expect(names.contains("ignoredFunction") == false)
    }
}
