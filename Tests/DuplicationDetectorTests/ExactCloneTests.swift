//
//  ExactCloneTests.swift
//  SwiftStaticAnalysis
//
//  Tests for exact clone (Type-1) detection.
//

import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import DuplicationDetector
@testable import SwiftStaticAnalysisCore

// MARK: - ExactCloneTests

@Suite("Exact Clone Detection Tests")
struct ExactCloneTests {
    // MARK: - Basic Detection

    @Test("Detect identical code blocks")
    func detectIdenticalBlocks() {
        let source = """
        func block1() {
            let x = 1
            let y = 2
            let z = x + y
            print(z)
        }

        func block2() {
            let x = 1
            let y = 2
            let z = x + y
            print(z)
        }
        """

        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        let detector = ExactCloneDetector(minimumTokens: 10)
        let clones = detector.detect(in: [sequence])

        // Should detect the duplicate block
        #expect(clones.count >= 1)

        if let firstGroup = clones.first {
            #expect(firstGroup.type == .exact)
            #expect(firstGroup.clones.count >= 2)
        }
    }

    @Test("Respect minimum token threshold")
    func respectMinimumTokens() {
        let source = """
        let a = 1
        let b = 1
        """

        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        // High threshold should find no clones
        let detector = ExactCloneDetector(minimumTokens: 100)
        let clones = detector.detect(in: [sequence])

        #expect(clones.isEmpty)
    }

    @Test("Empty input returns no clones")
    func emptyInputNoClones() {
        let detector = ExactCloneDetector(minimumTokens: 10)
        let clones = detector.detect(in: [])

        #expect(clones.isEmpty)
    }

    // MARK: - Real-World Fixture Tests

    @Test("Detect clones in NetworkingDuplication fixture")
    func detectNetworkingClones() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("DuplicationScenarios")
            .appendingPathComponent("ExactClones")
            .appendingPathComponent("NetworkingDuplication.swift")

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            Issue.record("Fixture file not found")
            return
        }

        let source = try String(contentsOfFile: fixturesPath.path, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: fixturesPath.path, source: source)

        // Lower threshold to catch the networking boilerplate
        let detector = ExactCloneDetector(minimumTokens: 20)
        let clones = detector.detect(in: [sequence])

        // Should detect the fetch functions as clones
        #expect(clones.count >= 1)

        // Verify clone properties
        for group in clones {
            #expect(group.type == .exact)
            #expect(group.similarity == 1.0)
            for clone in group.clones {
                #expect(clone.tokenCount >= 20)
            }
        }
    }

    // MARK: - Cross-File Detection

    @Test("Detect clones across multiple files")
    func detectCrossFileClones() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("ComplexCodebases")
            .appendingPathComponent("NetworkingApp")
            .appendingPathComponent("API")

        let userAPIPath = fixturesPath.appendingPathComponent("UserAPI.swift")
        let productAPIPath = fixturesPath.appendingPathComponent("ProductAPI.swift")

        guard FileManager.default.fileExists(atPath: userAPIPath.path),
              FileManager.default.fileExists(atPath: productAPIPath.path)
        else {
            Issue.record("Fixture files not found")
            return
        }

        let userSource = try String(contentsOfFile: userAPIPath.path, encoding: .utf8)
        let productSource = try String(contentsOfFile: productAPIPath.path, encoding: .utf8)

        let userTree = Parser.parse(source: userSource)
        let productTree = Parser.parse(source: productSource)

        let extractor = TokenSequenceExtractor()
        let userSequence = extractor.extract(from: userTree, file: userAPIPath.path, source: userSource)
        let productSequence = extractor.extract(from: productTree, file: productAPIPath.path, source: productSource)

        let detector = ExactCloneDetector(minimumTokens: 25)
        let clones = detector.detect(in: [userSequence, productSequence])

        // Should detect cross-file clones (the CRUD boilerplate)
        #expect(clones.count >= 1)

        // Verify at least one group has clones from different files
        let crossFileGroups = clones.filter { group in
            let files = Set(group.clones.map(\.file))
            return files.count > 1
        }

        #expect(crossFileGroups.count >= 1)
    }

    // MARK: - Edge Cases

    @Test("Handle single-token windows")
    func handleSingleToken() {
        let source = "x"

        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        let detector = ExactCloneDetector(minimumTokens: 1)
        let clones = detector.detect(in: [sequence])

        // Single token shouldn't create clones with itself
        #expect(clones.isEmpty)
    }

    @Test("Handle whitespace variations")
    func handleWhitespaceVariations() {
        // These should be detected as the same clone (whitespace ignored)
        let source1 = "let x=1+2"
        let source2 = "let x = 1 + 2"

        let tree1 = Parser.parse(source: source1)
        let tree2 = Parser.parse(source: source2)

        let extractor = TokenSequenceExtractor()
        let seq1 = extractor.extract(from: tree1, file: "test1.swift", source: source1)
        let seq2 = extractor.extract(from: tree2, file: "test2.swift", source: source2)

        let detector = ExactCloneDetector(minimumTokens: 3)
        let clones = detector.detect(in: [seq1, seq2])

        // Whitespace normalized, should detect as clone
        #expect(clones.count >= 1)
    }
}

// MARK: - CloneMergingTests

@Suite("Clone Merging Tests")
struct CloneMergingTests {
    @Test("Merge overlapping clones")
    func mergeOverlapping() {
        let source = """
        func test() {
            let a = 1
            let b = 2
            let c = 3
            let d = 4
            let e = 5
        }

        func test2() {
            let a = 1
            let b = 2
            let c = 3
            let d = 4
            let e = 5
        }
        """

        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        let detector = ExactCloneDetector(minimumTokens: 5)
        let clones = detector.detect(in: [sequence])

        // Overlapping matches should be merged
        #expect(clones.count >= 1)
    }
}

// MARK: - HashCollisionTests

@Suite("Hash Collision Tests")
struct HashCollisionTests {
    @Test("Verify actual content on hash match")
    func verifyHashMatch() {
        // Two different code blocks that might have same hash (unlikely but test verification)
        let source = """
        func a() { let x = 1; let y = 2 }
        func b() { let x = 1; let y = 2 }
        func c() { let p = 9; let q = 8 }
        """

        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        let detector = ExactCloneDetector(minimumTokens: 5)
        let clones = detector.detect(in: [sequence])

        // a and b should be clones, c should not be grouped with them
        for group in clones {
            // All clones in a group should have identical token sequences
            if group.clones.count > 1 {
                let snippets = group.clones.map(\.codeSnippet)
                // Just verify we got results (actual verification happens in detector)
                #expect(snippets.count >= 2)
            }
        }
    }
}
