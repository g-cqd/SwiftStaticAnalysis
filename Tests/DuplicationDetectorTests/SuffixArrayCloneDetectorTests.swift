//
//  SuffixArrayCloneDetectorTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify SuffixArrayCloneDetector initialization
//  - Test detection with various input scenarios
//
//  ## Coverage
//  - SuffixArrayCloneDetector: initialization, minimumTokens, normalizeForType2
//  - detect(): empty input, below threshold
//

import Foundation
import Testing
@testable import DuplicationDetector

@Suite("Suffix Array Clone Detector Tests")
struct SuffixArrayCloneDetectorTests {
    @Test("Detector initialization")
    func detectorInit() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 30)
        #expect(detector.minimumTokens == 30)
        #expect(detector.normalizeForType2 == false)
    }

    @Test("Detection with empty input")
    func detectEmptyInput() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 10)
        let result = detector.detect(in: [])
        #expect(result.isEmpty)
    }

    @Test("Detection with single sequence below threshold")
    func detectBelowThreshold() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 100)

        let tokens = (0 ..< 50).map { TokenInfo(kind: .identifier, text: "t\($0)", line: $0, column: 0) }
        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])

        let result = detector.detect(in: [sequence])
        #expect(result.isEmpty)
    }
}
