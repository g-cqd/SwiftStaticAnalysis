//  SemanticCloneDetectorTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import DuplicationDetector

@Suite("Semantic Clone Detector Tests")
struct SemanticCloneDetectorTests {
    @Test("SemanticCloneDetector initialization")
    func initialization() {
        let detector = SemanticCloneDetector(minimumNodes: 15, minimumSimilarity: 0.75)
        #expect(detector.minimumNodes == 15)
        #expect(detector.minimumSimilarity == 0.75)
    }
}
