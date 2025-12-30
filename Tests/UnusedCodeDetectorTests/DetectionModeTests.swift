//
//  DetectionModeTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify detection mode presets and configuration
//
//  ## Coverage
//  - Simple mode is default
//  - Reachability, IndexStore, Strict presets
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Detection Mode Tests")
struct DetectionModeTests {
    @Test("Simple mode is default")
    func defaultMode() {
        let config = UnusedCodeConfiguration()
        #expect(config.mode == .simple)
    }

    @Test("Reachability configuration preset")
    func reachabilityPreset() {
        let config = UnusedCodeConfiguration.reachability
        #expect(config.mode == .reachability)
    }

    @Test("IndexStore configuration preset")
    func indexStorePreset() {
        let config = UnusedCodeConfiguration.indexStore
        #expect(config.mode == .indexStore)
    }

    @Test("Strict configuration preset")
    func strictPreset() {
        let config = UnusedCodeConfiguration.strict
        #expect(config.mode == .reachability)
        #expect(config.ignorePublicAPI == false)
        #expect(config.treatPublicAsRoot == false)
        #expect(config.minimumConfidence == .low)
    }
}
