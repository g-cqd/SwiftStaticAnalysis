//  SwiftFileFinderTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

@Suite("SwiftFileFinder")
struct SwiftFileFinderTests {
    @Test("Strict preset finds .swift files and applies glob excludes")
    func strictFindsSwiftFilesAndExcludes() throws {
        let tmp = try makeFixture(layout: [
            "Sources/A.swift": "// A",
            "Sources/B.swift": "// B",
            "Tests/T.swift": "// T",
            "Sources/Notes.txt": "ignored",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let finder = SwiftFileFinder(options: .strict)
        let all = try finder.find(in: [tmp.path])
        let names = all.map { ($0 as NSString).lastPathComponent }
        #expect(names.contains("A.swift"))
        #expect(names.contains("B.swift"))
        #expect(names.contains("T.swift"))
        #expect(!names.contains("Notes.txt"))

        // Glob exclude pattern — should match the `**/Tests/**` fast path.
        let filtered = try finder.find(
            in: [tmp.path],
            excludePaths: ["**/Tests/**"]
        )
        #expect(filtered.allSatisfy { !$0.contains("/Tests/") })
    }

    @Test("Strict preset skips default-excluded directories")
    func strictSkipsDefaultExcluded() throws {
        let tmp = try makeFixture(layout: [
            "Sources/A.swift": "// A",
            ".build/staging/B.swift": "// build artifact",
            "Pods/SomePod/C.swift": "// vendored",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let files = try SwiftFileFinder(options: .strict).find(in: [tmp.path])
        #expect(files.allSatisfy { !$0.contains("/.build/") })
        #expect(files.allSatisfy { !$0.contains("/Pods/") })
        #expect(files.contains { $0.hasSuffix("A.swift") })
    }

    @Test("Fast preset skips hygiene checks")
    func fastPresetEnumeratesLiberally() throws {
        let tmp = try makeFixture(layout: [
            "A.swift": "// A",
            ".build/B.swift": "// would normally be excluded",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let files = try SwiftFileFinder(options: .fast).find(in: [tmp.path])
        // `.skipsHiddenFiles` still drops dot-directories at the
        // enumerator level, but no glob / deny-list filtering runs.
        #expect(files.contains { $0.hasSuffix("A.swift") })
    }

    @Test("Single file input is returned without enumeration")
    func singleFileShortCircuit() throws {
        let tmp = try makeFixture(layout: ["only.swift": "// hello"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let onlyFile = tmp.appendingPathComponent("only.swift").path
        let files = try SwiftFileFinder(options: .strict).find(in: [onlyFile])
        #expect(files == [onlyFile])
    }

    // MARK: - Fixture helpers

    private func makeFixture(layout: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa-swiftfilefinder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, contents) in layout {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
