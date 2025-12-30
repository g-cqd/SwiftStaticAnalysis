//
//  DependencyExtractionTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify DependencyExtractor initialization and configuration
//
//  ## Coverage
//  - Default configuration
//  - Custom configuration
//  - Strict configuration preset
//

import Foundation
import Testing
@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Dependency Extraction Tests")
struct DependencyExtractionTests {
    @Test("DependencyExtractor initialization")
    func extractorInitialization() {
        let extractor = DependencyExtractor()
        #expect(extractor.configuration.treatPublicAsRoot == true)
    }

    @Test("Custom extraction configuration")
    func customConfig() {
        let config = DependencyExtractionConfiguration(
            treatPublicAsRoot: false,
            treatObjcAsRoot: false,
            treatTestsAsRoot: false,
        )
        let extractor = DependencyExtractor(configuration: config)
        #expect(extractor.configuration.treatPublicAsRoot == false)
    }

    @Test("Strict configuration")
    func strictConfig() {
        let config = DependencyExtractionConfiguration.strict
        #expect(config.treatPublicAsRoot == false)
        #expect(config.treatObjcAsRoot == true)
    }
}
