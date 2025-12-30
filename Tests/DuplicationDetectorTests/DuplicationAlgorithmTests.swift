//
//  DuplicationAlgorithmTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify algorithm selection in DuplicationConfiguration
//  - Test preset configurations
//
//  ## Coverage
//  - Default algorithm is rollingHash
//  - High performance preset uses suffixArray
//  - Custom algorithm configuration
//

import Testing
@testable import DuplicationDetector

@Suite("Duplication Detector Algorithm Tests")
struct DuplicationDetectorAlgorithmTests {
    @Test("Default configuration uses rolling hash")
    func defaultAlgorithm() {
        let config = DuplicationConfiguration()
        #expect(config.algorithm == .rollingHash)
    }

    @Test("High performance configuration uses suffix array")
    func highPerformanceAlgorithm() {
        let config = DuplicationConfiguration.highPerformance
        #expect(config.algorithm == .suffixArray)
        #expect(config.cloneTypes.contains(.exact))
        #expect(config.cloneTypes.contains(.near))
    }

    @Test("Custom algorithm configuration")
    func customAlgorithm() {
        let config = DuplicationConfiguration(
            minimumTokens: 25,
            cloneTypes: [.exact],
            algorithm: .suffixArray,
        )
        #expect(config.algorithm == .suffixArray)
        #expect(config.minimumTokens == 25)
    }
}
