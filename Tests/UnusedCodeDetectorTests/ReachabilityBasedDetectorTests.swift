//  ReachabilityBasedDetectorTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

@Suite("Reachability-Based Detector Tests")
struct ReachabilityBasedDetectorTests {
    @Test("Detector initialization")
    func detectorInitialization() {
        let detector = ReachabilityBasedDetector()
        #expect(detector.configuration.mode == .simple)
    }

    @Test("Detector with reachability mode")
    func reachabilityModeConfig() {
        let config = UnusedCodeConfiguration.reachability
        #expect(config.mode == .reachability)
    }
}
