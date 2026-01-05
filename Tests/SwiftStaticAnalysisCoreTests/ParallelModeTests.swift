//
//  ParallelModeTests.swift
//  SwiftStaticAnalysis
//
//  Tests for ParallelMode enum and equivalence across modes.
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

// MARK: - ParallelModeTests

@Suite("ParallelMode Tests")
struct ParallelModeTests {
    // MARK: - Enum Properties

    @Test("isParallel returns correct values")
    func isParallelProperty() {
        #expect(ParallelMode.none.isParallel == false)
        #expect(ParallelMode.safe.isParallel == true)
        #expect(ParallelMode.maximum.isParallel == true)
    }

    @Test("usesStreaming only true for maximum mode")
    func usesStreamingProperty() {
        #expect(ParallelMode.none.usesStreaming == false)
        #expect(ParallelMode.safe.usesStreaming == false)
        #expect(ParallelMode.maximum.usesStreaming == true)
    }

    // MARK: - Legacy Conversion

    @Test("from(legacyParallel:) maps correctly")
    func fromLegacyParallel() {
        #expect(ParallelMode.from(legacyParallel: false) == .none)
        #expect(ParallelMode.from(legacyParallel: true) == .safe)
    }

    // MARK: - ConcurrencyConfiguration Conversion

    @Test("toConcurrencyConfiguration returns correct presets")
    func toConcurrencyConfiguration() {
        let noneConfig = ParallelMode.none.toConcurrencyConfiguration()
        #expect(noneConfig.enableParallelProcessing == false)
        #expect(noneConfig.maxConcurrentFiles == 1)

        let safeConfig = ParallelMode.safe.toConcurrencyConfiguration()
        #expect(safeConfig.enableParallelProcessing == true)

        let maxConfig = ParallelMode.maximum.toConcurrencyConfiguration()
        #expect(maxConfig.enableParallelProcessing == true)
        #expect(maxConfig.batchSize == 200)
    }

    @Test("toConcurrencyConfiguration respects maxConcurrency override")
    func toConcurrencyConfigurationWithOverride() {
        let config = ParallelMode.safe.toConcurrencyConfiguration(maxConcurrency: 4)
        #expect(config.maxConcurrentFiles == 4)
        #expect(config.maxConcurrentTasks == 8)
    }

    // MARK: - Codable

    @Test("ParallelMode encodes and decodes correctly")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in ParallelMode.allCases {
            let encoded = try encoder.encode(mode)
            let decoded = try decoder.decode(ParallelMode.self, from: encoded)
            #expect(decoded == mode)
        }
    }

    @Test("ParallelMode decodes from string")
    func decodesFromString() throws {
        let decoder = JSONDecoder()

        let noneData = "\"none\"".data(using: .utf8)!
        #expect(try decoder.decode(ParallelMode.self, from: noneData) == .none)

        let safeData = "\"safe\"".data(using: .utf8)!
        #expect(try decoder.decode(ParallelMode.self, from: safeData) == .safe)

        let maxData = "\"maximum\"".data(using: .utf8)!
        #expect(try decoder.decode(ParallelMode.self, from: maxData) == .maximum)
    }
}

// MARK: - Configuration Resolution Tests

@Suite("ParallelMode Configuration Resolution Tests")
struct ParallelModeConfigurationTests {
    // MARK: - UnusedConfiguration

    @Test("UnusedConfiguration.resolvedParallelMode prioritizes parallelMode over parallel")
    func unusedConfigParallelModesPriority() {
        // parallelMode takes precedence
        let config1 = UnusedConfiguration(parallel: true, parallelMode: ParallelMode.none)
        #expect(config1.resolvedParallelMode == ParallelMode.none)

        let config2 = UnusedConfiguration(parallel: false, parallelMode: .safe)
        #expect(config2.resolvedParallelMode == .safe)
    }

    @Test("UnusedConfiguration.resolvedParallelMode falls back to parallel flag")
    func unusedConfigParallelFallback() {
        let config1 = UnusedConfiguration(parallel: true)
        #expect(config1.resolvedParallelMode == .safe)

        let config2 = UnusedConfiguration(parallel: false)
        #expect(config2.resolvedParallelMode == .none)
    }

    @Test("UnusedConfiguration.resolvedParallelMode defaults to none")
    func unusedConfigDefault() {
        let config = UnusedConfiguration()
        #expect(config.resolvedParallelMode == .none)
    }

    // MARK: - DuplicatesConfiguration

    @Test("DuplicatesConfiguration.resolvedParallelMode prioritizes parallelMode over parallel")
    func duplicatesConfigParallelModesPriority() {
        // parallelMode takes precedence
        let config1 = DuplicatesConfiguration(parallel: true, parallelMode: ParallelMode.none)
        #expect(config1.resolvedParallelMode == ParallelMode.none)

        let config2 = DuplicatesConfiguration(parallel: false, parallelMode: .maximum)
        #expect(config2.resolvedParallelMode == .maximum)
    }

    @Test("DuplicatesConfiguration.resolvedParallelMode falls back to parallel flag")
    func duplicatesConfigParallelFallback() {
        let config1 = DuplicatesConfiguration(parallel: true)
        #expect(config1.resolvedParallelMode == .safe)

        let config2 = DuplicatesConfiguration(parallel: false)
        #expect(config2.resolvedParallelMode == .none)
    }

    @Test("DuplicatesConfiguration.resolvedParallelMode defaults to none")
    func duplicatesConfigDefault() {
        let config = DuplicatesConfiguration()
        #expect(config.resolvedParallelMode == .none)
    }

    // MARK: - JSON Configuration

    @Test("Configuration loads parallelMode from JSON")
    func loadsParallelModeFromJSON() throws {
        let json = """
        {
            "unused": {
                "parallelMode": "safe"
            },
            "duplicates": {
                "parallelMode": "maximum"
            }
        }
        """

        let decoder = JSONDecoder()
        let config = try decoder.decode(SWAConfiguration.self, from: json.data(using: .utf8)!)

        #expect(config.unused?.parallelMode == .safe)
        #expect(config.duplicates?.parallelMode == .maximum)
    }

    @Test("Configuration handles both parallel and parallelMode in JSON")
    func loadsLegacyAndNewFromJSON() throws {
        let json = """
        {
            "unused": {
                "parallel": true,
                "parallelMode": "maximum"
            }
        }
        """

        let decoder = JSONDecoder()
        let config = try decoder.decode(SWAConfiguration.self, from: json.data(using: .utf8)!)

        // parallelMode should take precedence
        #expect(config.unused?.resolvedParallelMode == .maximum)
    }
}
