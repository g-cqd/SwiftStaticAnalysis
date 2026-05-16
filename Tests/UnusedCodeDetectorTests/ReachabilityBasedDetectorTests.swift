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

    @Test("Dead-branch pass surfaces if-false branches when enabled")
    func deadBranchPassEmitsFindings() async throws {
        // Write a tiny fixture containing one provably-dead branch.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa-dead-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("Sample.swift")
        try """
            func deadExample() {
                if false {
                    print("never")
                }
            }
            """.write(to: file, atomically: true, encoding: .utf8)

        let config = UnusedCodeConfiguration(
            mode: .reachability,
            detectDeadBranches: true
        )
        let detector = UnusedCodeDetector(configuration: config)
        let findings = try await detector.detectUnused(in: [file.path])
        #expect(findings.contains { $0.reason == .deadBranch })
    }

    @Test("Dead-branch pass is silent when not enabled")
    func deadBranchPassOffByDefault() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa-dead-branch-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("Sample.swift")
        try """
            func deadExample() {
                if false {
                    print("never")
                }
            }
            """.write(to: file, atomically: true, encoding: .utf8)

        // Default config — detectDeadBranches off.
        let detector = UnusedCodeDetector(configuration: .reachability)
        let findings = try await detector.detectUnused(in: [file.path])
        #expect(!findings.contains { $0.reason == .deadBranch })
    }
}
