//  NearCloneDetectorTests.swift
//  SwiftStaticAnalysis
//  MIT License

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
