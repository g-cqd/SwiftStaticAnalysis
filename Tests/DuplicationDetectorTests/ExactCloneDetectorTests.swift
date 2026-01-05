//  ExactCloneDetectorTests.swift
//  SwiftStaticAnalysis
//  MIT License

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
