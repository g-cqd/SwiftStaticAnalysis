//  PerformanceTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore
import Testing

@testable import SymbolLookup

@Suite("Symbol Lookup Performance Tests")
struct SymbolLookupPerformanceTests {
    // MARK: - Batch Query Performance

    @Test("Batch queries parallel vs sequential - small batch")
    func batchQueriesSmallBatch() async throws {
        let finder = SymbolFinder()

        // Small batch (< threshold) should use sequential
        let queries = (1...2).map { SymbolQuery.name("Symbol\($0)") }

        let results = try await finder.findMultiple(queries, parallelMode: .safe)

        // Should complete without error (finder has no index, so results empty)
        #expect(results.count == queries.count)
    }

    @Test("Batch queries parallel vs sequential - medium batch")
    func batchQueriesMediumBatch() async throws {
        let finder = SymbolFinder()

        // Medium batch (>= threshold) should use parallel
        let queries = (1...10).map { SymbolQuery.name("Symbol\($0)") }

        let results = try await finder.findMultiple(queries, parallelMode: .safe)

        #expect(results.count == queries.count)
    }

    @Test("Batch queries with none parallel mode uses sequential")
    func batchQueriesNoneMode() async throws {
        let finder = SymbolFinder()

        let queries = (1...10).map { SymbolQuery.name("Symbol\($0)") }

        let results = try await finder.findMultiple(queries, parallelMode: .none)

        #expect(results.count == queries.count)
    }

    @Test("Batch queries with maximum parallel mode")
    func batchQueriesMaximumMode() async throws {
        let finder = SymbolFinder()

        let queries = (1...10).map { SymbolQuery.name("Symbol\($0)") }

        let results = try await finder.findMultiple(queries, parallelMode: .maximum)

        #expect(results.count == queries.count)
    }

    @Test("Empty batch returns empty dictionary")
    func emptyBatchReturnsEmpty() async throws {
        let finder = SymbolFinder()

        let results = try await finder.findMultiple([], parallelMode: .safe)

        #expect(results.isEmpty)
    }

    // MARK: - USR Reference Checking Performance

    @Test("USR reference checking - small set uses sequential")
    func usrCheckingSmallSet() async {
        let finder = SymbolFinder()

        // Small set (< threshold) should use sequential
        let usrs = (1...10).map { "usr_\($0)" }

        let referenced = await finder.findReferencedUSRs(usrs, parallelMode: .safe)

        // No index store, so should return empty
        #expect(referenced.isEmpty)
    }

    @Test("USR reference checking - large set uses parallel chunking")
    func usrCheckingLargeSet() async {
        let finder = SymbolFinder()

        // Large set (>= threshold) should use parallel chunking
        let usrs = (1...100).map { "usr_\($0)" }

        let referenced = await finder.findReferencedUSRs(usrs, parallelMode: .safe)

        // No index store, so should return empty
        #expect(referenced.isEmpty)
    }

    @Test("USR reference checking - none mode uses sequential")
    func usrCheckingNoneMode() async {
        let finder = SymbolFinder()

        let usrs = (1...100).map { "usr_\($0)" }

        let referenced = await finder.findReferencedUSRs(usrs, parallelMode: .none)

        #expect(referenced.isEmpty)
    }

    @Test("USR reference checking - empty set returns empty")
    func usrCheckingEmptySet() async {
        let finder = SymbolFinder()

        let referenced = await finder.findReferencedUSRs([], parallelMode: .safe)

        #expect(referenced.isEmpty)
    }

    @Test("Synchronous USR checking works")
    func synchronousUsrChecking() {
        let finder = SymbolFinder()

        let usrs = (1...10).map { "usr_\($0)" }

        let referenced = finder.findReferencedUSRs(usrs)

        #expect(referenced.isEmpty)
    }
}

@Suite("RegexCache Performance Tests")
struct RegexCachePerformanceTests {
    @Test("Cache returns same regex for same pattern")
    func cacheReturnsSameRegex() {
        let cache = RegexCache()

        let regex1 = cache.regex(for: "test.*pattern")
        let regex2 = cache.regex(for: "test.*pattern")

        #expect(regex1 != nil)
        #expect(regex2 != nil)
        #expect(cache.count == 1)
    }

    @Test("Cache handles multiple patterns")
    func cacheHandlesMultiplePatterns() {
        let cache = RegexCache()

        let patterns = (1...10).map { "pattern_\($0).*" }
        for pattern in patterns {
            _ = cache.regex(for: pattern)
        }

        #expect(cache.count == 10)
    }

    @Test("Cache evicts when at capacity")
    func cacheEvictsAtCapacity() {
        let cache = RegexCache(capacity: 5)

        // Add 6 patterns
        for i in 1...6 {
            _ = cache.regex(for: "pattern_\(i)")
        }

        // Should have evicted first pattern
        #expect(cache.count == 5)
    }

    @Test("Cache returns nil for invalid pattern")
    func cacheReturnsNilForInvalid() {
        let cache = RegexCache()

        // Invalid regex pattern (unclosed bracket)
        let regex = cache.regex(for: "[invalid")

        #expect(regex == nil)
        #expect(cache.count == 0)
    }

    @Test("Cache isCached returns correct state")
    func cacheIsCachedWorks() {
        let cache = RegexCache()

        #expect(!cache.isCached("test.*"))

        _ = cache.regex(for: "test.*")

        #expect(cache.isCached("test.*"))
    }

    @Test("Cache clear removes all patterns")
    func cacheClearWorks() {
        let cache = RegexCache()

        for i in 1...5 {
            _ = cache.regex(for: "pattern_\(i)")
        }

        #expect(cache.count == 5)

        cache.clear()

        #expect(cache.count == 0)
    }

    @Test("Shared cache is accessible")
    func sharedCacheAccessible() {
        let shared = RegexCache.shared

        #expect(shared != nil)
    }
}

@Suite("ParallelMode Configuration Tests")
struct ParallelModeConfigurationTests {
    @Test("None mode is not parallel")
    func noneModeNotParallel() {
        let mode = ParallelMode.none

        #expect(!mode.isParallel)
        #expect(!mode.usesStreaming)
    }

    @Test("Safe mode is parallel")
    func safeModeIsParallel() {
        let mode = ParallelMode.safe

        #expect(mode.isParallel)
        #expect(!mode.usesStreaming)
    }

    @Test("Maximum mode is parallel with streaming")
    func maximumModeIsParallelWithStreaming() {
        let mode = ParallelMode.maximum

        #expect(mode.isParallel)
        #expect(mode.usesStreaming)
    }

    @Test("Legacy parallel true maps to safe")
    func legacyParallelTrueMapsToSafe() {
        let mode = ParallelMode.from(legacyParallel: true)

        #expect(mode == .safe)
    }

    @Test("Legacy parallel false maps to none")
    func legacyParallelFalseMapsToNone() {
        let mode = ParallelMode.from(legacyParallel: false)

        #expect(mode == .none)
    }

    @Test("Concurrency configuration for none is serial")
    func concurrencyConfigNoneIsSerial() {
        let config = ParallelMode.none.toConcurrencyConfiguration()

        #expect(!config.enableParallelProcessing)
        #expect(config.maxConcurrentFiles == 1)
        #expect(config.maxConcurrentTasks == 1)
    }

    @Test("Concurrency configuration for safe uses defaults")
    func concurrencyConfigSafeUsesDefaults() {
        let config = ParallelMode.safe.toConcurrencyConfiguration()

        #expect(config.enableParallelProcessing)
        #expect(config.maxConcurrentFiles >= 1)
        #expect(config.maxConcurrentTasks >= 1)
    }

    @Test("Concurrency configuration for maximum is high throughput")
    func concurrencyConfigMaximumIsHighThroughput() {
        let config = ParallelMode.maximum.toConcurrencyConfiguration()

        #expect(config.enableParallelProcessing)
        #expect(config.maxConcurrentFiles >= 1)
        #expect(config.maxConcurrentTasks >= config.maxConcurrentFiles)
    }

    @Test("Custom max concurrency is respected")
    func customMaxConcurrencyRespected() {
        let config = ParallelMode.safe.toConcurrencyConfiguration(maxConcurrency: 4)

        #expect(config.maxConcurrentFiles == 4)
        #expect(config.maxConcurrentTasks == 8)
    }
}

@Suite("ConcurrencyConfiguration Tests")
struct ConcurrencyConfigurationTests {
    @Test("Default configuration has reasonable values")
    func defaultConfigHasReasonableValues() {
        let config = ConcurrencyConfiguration.default

        #expect(config.enableParallelProcessing)
        #expect(config.maxConcurrentFiles >= 1)
        #expect(config.maxConcurrentTasks >= 1)
        #expect(config.batchSize == 100)
    }

    @Test("Serial configuration is single-threaded")
    func serialConfigIsSingleThreaded() {
        let config = ConcurrencyConfiguration.serial

        #expect(!config.enableParallelProcessing)
        #expect(config.maxConcurrentFiles == 1)
        #expect(config.maxConcurrentTasks == 1)
    }

    @Test("High throughput configuration has larger values")
    func highThroughputHasLargerValues() {
        let config = ConcurrencyConfiguration.highThroughput

        #expect(config.enableParallelProcessing)
        #expect(config.maxConcurrentFiles >= ConcurrencyConfiguration.default.maxConcurrentFiles)
        #expect(config.batchSize == 200)
    }

    @Test("Conservative configuration has smaller values")
    func conservativeHasSmallerValues() {
        let config = ConcurrencyConfiguration.conservative

        #expect(config.enableParallelProcessing)
        #expect(config.maxConcurrentFiles >= 1)
        #expect(config.batchSize == 50)
    }

    @Test("Custom configuration values are respected")
    func customValuesRespected() {
        let config = ConcurrencyConfiguration(
            maxConcurrentFiles: 8,
            maxConcurrentTasks: 16,
            enableParallelProcessing: true,
            batchSize: 50
        )

        #expect(config.maxConcurrentFiles == 8)
        #expect(config.maxConcurrentTasks == 16)
        #expect(config.enableParallelProcessing)
        #expect(config.batchSize == 50)
    }
}
