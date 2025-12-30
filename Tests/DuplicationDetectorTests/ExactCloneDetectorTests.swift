//
//  ExactCloneDetectorTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify ExactCloneDetector initialization
//  - Test empty sequence handling
//
//  ## Coverage
//  - ExactCloneDetector: initialization with minimumTokens
//  - detect(): empty input returns empty result
//
//  ## Gaps
//  - Missing: actual clone detection with duplicate sequences
//  - Missing: threshold behavior testing
//

import Testing
@testable import DuplicationDetector

@Suite("Exact Clone Detector Tests")
struct ExactCloneDetectorTests {
    @Test("ExactCloneDetector initialization")
    func initialization() {
        let detector = ExactCloneDetector(minimumTokens: 30)
        #expect(detector.minimumTokens == 30)
    }

    @Test("Empty sequence returns no clones")
    func emptySequenceNoClones() {
        let detector = ExactCloneDetector(minimumTokens: 5)
        let clones = detector.detect(in: [])
        #expect(clones.isEmpty)
    }
}
