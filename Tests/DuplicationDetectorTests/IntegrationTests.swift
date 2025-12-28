//
//  IntegrationTests.swift
//  SwiftStaticAnalysis
//
//  End-to-end integration tests for the duplication detector.
//

import Foundation
import Testing
@testable import DuplicationDetector
@testable import SwiftStaticAnalysisCore

@Suite("Duplication Detector Integration Tests")
struct DuplicationDetectorIntegrationTests {

    // MARK: - Full Pipeline Tests

    @Test("Full detection pipeline on exact clones")
    func fullPipelineExactClones() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("DuplicationScenarios")
            .appendingPathComponent("ExactClones")
            .appendingPathComponent("NetworkingDuplication.swift")

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            Issue.record("Fixture file not found at \(fixturesPath.path)")
            return
        }

        let config = DuplicationConfiguration(
            minimumTokens: 20,
            cloneTypes: [.exact]
        )

        let detector = DuplicationDetector(configuration: config)
        let result = try await detector.detectClones(in: [fixturesPath.path])

        #expect(result.count >= 1)

        // Verify report properties
        for group in result {
            #expect(group.type == .exact)
            #expect(group.clones.count >= 2)
            #expect(group.similarity == 1.0)
        }
    }

    @Test("Full detection pipeline on near clones")
    func fullPipelineNearClones() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("DuplicationScenarios")
            .appendingPathComponent("NearClones")
            .appendingPathComponent("ViewModelDuplication.swift")

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            Issue.record("Fixture file not found")
            return
        }

        let config = DuplicationConfiguration(
            minimumTokens: 15,
            cloneTypes: [.near],
            minimumSimilarity: 0.7
        )

        let detector = DuplicationDetector(configuration: config)
        let result = try await detector.detectClones(in: [fixturesPath.path])

        #expect(result.count >= 1)

        for group in result {
            #expect(group.type == .near)
            #expect(group.similarity >= 0.7)
        }
    }

    @Test("Full detection pipeline on semantic clones")
    func fullPipelineSemanticClones() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("DuplicationScenarios")
            .appendingPathComponent("SemanticClones")
            .appendingPathComponent("AlgorithmicEquivalence.swift")

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            Issue.record("Fixture file not found")
            return
        }

        let config = DuplicationConfiguration(
            minimumTokens: 10,
            cloneTypes: [.semantic],
            minimumSimilarity: 0.6
        )

        let detector = DuplicationDetector(configuration: config)
        let result = try await detector.detectClones(in: [fixturesPath.path])

        // May or may not find semantic clones depending on algorithm sensitivity
        for group in result {
            #expect(group.type == .semantic)
        }
    }

    // MARK: - Multi-File Detection

    @Test("Detect clones across multiple files")
    func detectCrossFileClones() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("ComplexCodebases")
            .appendingPathComponent("NetworkingApp")
            .appendingPathComponent("API")

        let files = [
            fixturesPath.appendingPathComponent("UserAPI.swift").path,
            fixturesPath.appendingPathComponent("ProductAPI.swift").path,
            fixturesPath.appendingPathComponent("OrderAPI.swift").path
        ]

        for file in files {
            guard FileManager.default.fileExists(atPath: file) else {
                Issue.record("Fixture file not found: \(file)")
                return
            }
        }

        let config = DuplicationConfiguration(
            minimumTokens: 25,
            cloneTypes: [.exact, .near],
            minimumSimilarity: 0.8
        )

        let detector = DuplicationDetector(configuration: config)
        let result = try await detector.detectClones(in: files)

        // Should find cross-file clones (the API boilerplate)
        #expect(result.count >= 1)

        // Verify at least one group spans multiple files
        let crossFileGroups = result.filter { group in
            let uniqueFiles = Set(group.clones.map(\.file))
            return uniqueFiles.count > 1
        }

        #expect(crossFileGroups.count >= 1)
    }

    // MARK: - All Clone Types Together

    @Test("Detect all clone types simultaneously")
    func detectAllCloneTypes() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("DuplicationScenarios")
            .appendingPathComponent("ExactClones")
            .appendingPathComponent("NetworkingDuplication.swift")

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            Issue.record("Fixture file not found")
            return
        }

        let config = DuplicationConfiguration(
            minimumTokens: 15,
            cloneTypes: [.exact, .near, .semantic],
            minimumSimilarity: 0.7
        )

        let detector = DuplicationDetector(configuration: config)
        let result = try await detector.detectClones(in: [fixturesPath.path])

        // Should find at least some clones
        #expect(result.count >= 1)

        // Group by type
        let byType = Dictionary(grouping: result, by: \.type)

        // Should have at least exact clones (the file has intentional duplicates)
        #expect(byType[.exact]?.count ?? 0 >= 1)
    }

    // MARK: - Report Generation

    @Test("Generate duplication report")
    func generateReport() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("DuplicationScenarios")
            .appendingPathComponent("ExactClones")
            .appendingPathComponent("NetworkingDuplication.swift")

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            Issue.record("Fixture file not found")
            return
        }

        let config = DuplicationConfiguration(
            minimumTokens: 20,
            cloneTypes: [.exact]
        )

        let detector = DuplicationDetector(configuration: config)
        let clones = try await detector.detectClones(in: [fixturesPath.path])

        // Build report manually for now
        let report = DuplicationReport(
            filesAnalyzed: 1,
            totalLines: 100, // Approximate
            cloneGroups: clones
        )

        #expect(report.filesAnalyzed == 1)
        #expect(report.cloneGroups.count == clones.count)

        if !clones.isEmpty {
            #expect(report.duplicatedLines > 0)
            #expect(report.duplicationPercentage > 0)
        }
    }

    // MARK: - Edge Cases

    @Test("Handle non-existent file gracefully")
    func handleNonExistentFile() async throws {
        let config = DuplicationConfiguration.default
        let detector = DuplicationDetector(configuration: config)

        do {
            _ = try await detector.detectClones(in: ["/nonexistent/file.swift"])
            Issue.record("Should have thrown for non-existent file")
        } catch {
            // Expected - should throw an error for non-existent file
        }
    }

    @Test("Handle empty file list")
    func handleEmptyFileList() async throws {
        let config = DuplicationConfiguration.default
        let detector = DuplicationDetector(configuration: config)

        let result = try await detector.detectClones(in: [])

        #expect(result.isEmpty)
    }
}

@Suite("Configuration Tests")
struct ConfigurationIntegrationTests {

    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = DuplicationConfiguration.default

        #expect(config.minimumTokens == 50)
        #expect(config.cloneTypes.contains(.exact))
        #expect(config.minimumSimilarity == 0.8)
    }

    @Test("Custom configuration")
    func customConfiguration() {
        let config = DuplicationConfiguration(
            minimumTokens: 25,
            cloneTypes: [.exact, .near],
            ignoredPatterns: ["test_", "mock_"],
            minimumSimilarity: 0.75
        )

        #expect(config.minimumTokens == 25)
        #expect(config.cloneTypes.count == 2)
        #expect(config.minimumSimilarity == 0.75)
        #expect(config.ignoredPatterns.count == 2)
    }
}
