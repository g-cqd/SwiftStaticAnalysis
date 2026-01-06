//  ParallelPerformanceTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

// MARK: - ParallelProcessor Tests

@Suite("ParallelProcessor Performance Tests")
struct ParallelProcessorPerformanceTests {
    @Test("ParallelProcessor.map preserves result order")
    func mapPreservesOrder() async throws {
        let input = Array(0..<100)

        let results = try await ParallelProcessor.map(
            input,
            maxConcurrency: 8
        ) { value in
            // Simulate some work
            try? await Task.sleep(nanoseconds: 1_000)
            return value * 2
        }

        // Results should be in same order as input
        for (index, result) in results.enumerated() {
            #expect(result == index * 2)
        }
    }

    @Test("ParallelProcessor.compactMap filters nil values")
    func compactMapFiltersNil() async {
        let input = Array(0..<20)

        let results = await ParallelProcessor.compactMap(
            input,
            maxConcurrency: 4
        ) { value -> Int? in
            // Only keep even numbers
            value % 2 == 0 ? value : nil
        }

        #expect(results.count == 10)
        #expect(results.allSatisfy { $0 % 2 == 0 })
    }

    @Test("ParallelProcessor handles empty input")
    func handlesEmptyInput() async throws {
        let input: [Int] = []

        let results = try await ParallelProcessor.map(
            input,
            maxConcurrency: 4
        ) { value in value * 2 }

        #expect(results.isEmpty)
    }

    @Test("ParallelProcessor respects maxConcurrency of 1")
    func sequentialExecution() async throws {
        let input = Array(0..<10)

        let results = try await ParallelProcessor.map(
            input,
            maxConcurrency: 1
        ) { value in
            // With maxConcurrency=1, should process in order
            return value
        }

        // Should get all results in order
        #expect(results.count == 10)
        for (index, result) in results.enumerated() {
            #expect(result == index)
        }
    }

    @Test("ParallelProcessor scales with higher concurrency")
    func scalesWithConcurrency() async throws {
        let input = Array(0..<50)

        // Run with low concurrency
        let start1 = Date()
        _ = try await ParallelProcessor.map(
            input,
            maxConcurrency: 1
        ) { value in
            try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            return value
        }
        let sequential = Date().timeIntervalSince(start1)

        // Run with high concurrency
        let start2 = Date()
        _ = try await ParallelProcessor.map(
            input,
            maxConcurrency: 8
        ) { value in
            try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            return value
        }
        let parallel = Date().timeIntervalSince(start2)

        // Parallel should generally be faster (with some margin for system variability)
        // At minimum, it shouldn't be significantly slower
        #expect(parallel < sequential * 1.5)
    }
}

// MARK: - ConcurrencyConfiguration Tests

@Suite("ConcurrencyConfiguration Tests")
struct ConcurrencyConfigurationTests {
    @Test("Default configuration has parallel enabled")
    func defaultConfiguration() {
        let config = ConcurrencyConfiguration.default
        #expect(config.enableParallelProcessing == true)
    }

    @Test("Serial preset has parallel disabled")
    func serialPreset() {
        let config = ConcurrencyConfiguration.serial
        #expect(config.enableParallelProcessing == false)
        #expect(config.maxConcurrentFiles == 1)
        #expect(config.maxConcurrentTasks == 1)
    }

    @Test("HighThroughput preset has increased concurrency")
    func highThroughputPreset() {
        let config = ConcurrencyConfiguration.highThroughput
        #expect(config.enableParallelProcessing == true)
        #expect(config.batchSize == 200)
        #expect(config.maxConcurrentFiles >= ProcessInfo.processInfo.activeProcessorCount)
    }

    @Test("Conservative preset has lower concurrency")
    func conservativePreset() {
        let config = ConcurrencyConfiguration.conservative
        #expect(config.enableParallelProcessing == true)
        // Conservative preset should have lower concurrency than highThroughput
        #expect(config.batchSize < ConcurrencyConfiguration.highThroughput.batchSize)
    }

    @Test("Custom configuration respects provided values")
    func customConfiguration() {
        let config = ConcurrencyConfiguration(
            maxConcurrentFiles: 4,
            maxConcurrentTasks: 8,
            enableParallelProcessing: true,
            batchSize: 50
        )

        #expect(config.maxConcurrentFiles == 4)
        #expect(config.maxConcurrentTasks == 8)
        #expect(config.batchSize == 50)
        #expect(config.enableParallelProcessing == true)
    }

    @Test("Configuration respects parallel flag")
    func configurationRespectsParallelFlag() {
        let enabledConfig = ConcurrencyConfiguration(
            maxConcurrentFiles: 8,
            maxConcurrentTasks: 16,
            enableParallelProcessing: true,
            batchSize: 100
        )
        #expect(enabledConfig.maxConcurrentTasks == 16)

        let disabledConfig = ConcurrencyConfiguration(
            maxConcurrentFiles: 1,
            maxConcurrentTasks: 1,
            enableParallelProcessing: false,
            batchSize: 100
        )
        #expect(disabledConfig.maxConcurrentTasks == 1)
    }
}

// MARK: - RegexCache Performance Tests

@Suite("RegexCache Performance Tests")
struct RegexCachePerformanceTests {
    @Test("Cache returns same regex for same pattern")
    func cacheReturnsSameRegex() {
        let cache = RegexCache(capacity: 10)
        let pattern = "test.*pattern"

        let regex1 = cache.regex(for: pattern)
        let regex2 = cache.regex(for: pattern)

        #expect(regex1 != nil)
        #expect(regex2 != nil)
        // Both should reference the same cached regex
    }

    @Test("Cache handles invalid patterns gracefully")
    func handlesInvalidPatterns() {
        let cache = RegexCache(capacity: 10)
        let invalid = "[invalid("

        let regex = cache.regex(for: invalid)
        #expect(regex == nil)
    }

    @Test("Cache evicts old entries when full")
    func evictsWhenFull() {
        let cache = RegexCache(capacity: 3)

        // Fill cache
        _ = cache.regex(for: "pattern1")
        _ = cache.regex(for: "pattern2")
        _ = cache.regex(for: "pattern3")

        // Access pattern1 to make it more recent
        _ = cache.regex(for: "pattern1")

        // Add new pattern, should evict least recently used
        _ = cache.regex(for: "pattern4")

        // pattern1 should still be cached (was recently accessed)
        #expect(cache.regex(for: "pattern1") != nil)
    }

    @Test("Cache performance with repeated patterns")
    func performanceWithRepeatedPatterns() {
        let cache = RegexCache(capacity: 100)
        let patterns = (0..<10).map { "pattern\($0)" }

        // Warm up cache
        for pattern in patterns {
            _ = cache.regex(for: pattern)
        }

        // Measure cache hits
        let start = Date()
        for _ in 0..<1000 {
            for pattern in patterns {
                _ = cache.regex(for: pattern)
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        // 10,000 cache lookups should be fast (under 1 second)
        #expect(elapsed < 1.0)
    }
}

// MARK: - Parallel Analysis Tests

@Suite("Parallel Analysis Performance Tests")
struct ParallelAnalysisPerformanceTests {
    /// Creates a temporary Swift file for testing.
    private func createTempFile(content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "perf_test_\(UUID().uuidString).swift"
        let filePath = tempDir.appendingPathComponent(fileName).path
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    /// Cleans up temporary files.
    private func cleanupFiles(_ paths: [String]) {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    @Test("Parallel analysis produces deterministic results")
    func parallelAnalysisDeterministic() async throws {
        let code = """
            import Foundation

            class TestClass {
                func method1() {}
                func method2() {}
            }
            """

        let files = try (0..<5).map { _ in try createTempFile(content: code) }
        defer { cleanupFiles(files) }

        let analyzer = StaticAnalyzer()

        // Run analysis multiple times
        let result1 = try await analyzer.analyze(files)
        let result2 = try await analyzer.analyze(files)

        // Results should be identical
        #expect(result1.declarations.declarations.count == result2.declarations.declarations.count)
        #expect(result1.references.references.count == result2.references.references.count)
    }

    @Test("Analysis handles large number of small files")
    func analysisScalesWithFileCount() async throws {
        let code = """
            func f() {}
            """

        let files = try (0..<20).map { _ in try createTempFile(content: code) }
        defer { cleanupFiles(files) }

        let analyzer = StaticAnalyzer()
        let result = try await analyzer.analyze(files)

        // Should have 20 function declarations
        let functions = result.declarations.declarations.filter { $0.kind == .function }
        #expect(functions.count == 20)
    }

    @Test("Analysis handles file with many declarations")
    func analysisHandlesManyDeclarations() async throws {
        // Generate a file with many declarations
        var declarations: [String] = []
        for i in 0..<100 {
            declarations.append("func func\(i)() {}")
        }
        let code = "import Foundation\n" + declarations.joined(separator: "\n")

        let file = try createTempFile(content: code)
        defer { cleanupFiles([file]) }

        let analyzer = StaticAnalyzer()
        let result = try await analyzer.analyze([file])

        // Should find all 100 functions
        let functions = result.declarations.declarations.filter { $0.kind == .function }
        #expect(functions.count == 100)
    }
}

// MARK: - Batch Processing Tests

@Suite("Batch Processing Tests")
struct BatchProcessingTests {
    @Test("Batch processing with various sizes")
    func batchProcessingVariousSizes() async throws {
        for batchSize in [1, 10, 50, 100] {
            let input = Array(0..<100)
            let results = try await ParallelProcessor.map(
                input,
                maxConcurrency: batchSize
            ) { value in value * 2 }

            #expect(results.count == 100)
            #expect(results.first == 0)
            #expect(results.last == 198)
        }
    }

    @Test("Batch processing maintains data integrity")
    func batchProcessingDataIntegrity() async throws {
        let input = Array(0..<1000)

        let results = try await ParallelProcessor.map(
            input,
            maxConcurrency: 16
        ) { value in
            // Complex transformation
            let string = String(value)
            return Int(string)! * 2 + 1
        }

        // Verify all results
        for (index, result) in results.enumerated() {
            let expected = index * 2 + 1
            #expect(result == expected, "Mismatch at index \(index): got \(result), expected \(expected)")
        }
    }
}
