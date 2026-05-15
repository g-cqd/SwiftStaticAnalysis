//  VersionTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

@Suite("Version Source-of-Truth Tests", .tags(.unit))
struct VersionTests {
    @Test("swaVersion matches the top CHANGELOG entry")
    func versionMatchesChangelog() throws {
        // Locate CHANGELOG.md relative to this source file. The test executable
        // can run from various working directories (Xcode, `swift test`, CI),
        // so we walk up from #filePath until we find the repository root.
        let testFile = URL(fileURLWithPath: #filePath)
        var dir = testFile.deletingLastPathComponent()
        var changelog: URL?
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("CHANGELOG.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                changelog = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }

        let url = try #require(changelog, "CHANGELOG.md not found above \(testFile.path)")
        let contents = try String(contentsOf: url, encoding: .utf8)

        // Find the first `## [x.y.z]` header — that is the unreleased or
        // most-recent release entry. The repo's release policy is to add a
        // new top-most entry whenever `swaVersion` is bumped.
        let pattern = #/^##\s+\[(?<version>\d+\.\d+\.\d+)\]/#
        let topVersion = contents
            .split(separator: "\n")
            .lazy
            .compactMap { line -> String? in
                guard let match = try? pattern.firstMatch(in: line) else { return nil }
                return String(match.output.version)
            }
            .first

        let resolved = try #require(topVersion, "No `## [x.y.z]` heading found in CHANGELOG.md")
        #expect(
            resolved == swaVersion,
            "swaVersion (\(swaVersion)) is out of sync with top CHANGELOG entry (\(resolved)). Bump one or the other."
        )
    }
}
