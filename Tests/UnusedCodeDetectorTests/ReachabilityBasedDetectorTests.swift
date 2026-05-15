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
        // `UnusedCodeConfiguration.default.mode` is `.reachability` —
        // it's the README-documented contract and the mode that
        // matches the post-α.16 docs.
        #expect(detector.configuration.mode == .reachability)
    }

    @Test("Detector with reachability mode")
    func reachabilityModeConfig() {
        let config = UnusedCodeConfiguration.reachability
        #expect(config.mode == .reachability)
    }
}
