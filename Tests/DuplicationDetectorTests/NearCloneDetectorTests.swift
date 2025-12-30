//
//  NearCloneDetectorTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify NearCloneDetector initialization
//
//  ## Coverage
//  - NearCloneDetector: initialization with minimumTokens, minimumSimilarity
//
//  ## Gaps
//  - Missing: actual near-clone detection testing
//  - Missing: similarity threshold behavior
//  - Missing: identifier normalization impact testing
//

import Testing

@testable import DuplicationDetector

@Suite("Near Clone Detector Tests")
struct NearCloneDetectorTests {
    @Test("NearCloneDetector initialization")
    func initialization() {
        let detector = NearCloneDetector(minimumTokens: 25, minimumSimilarity: 0.9)
        #expect(detector.minimumTokens == 25)
        #expect(detector.minimumSimilarity == 0.9)
    }
}
