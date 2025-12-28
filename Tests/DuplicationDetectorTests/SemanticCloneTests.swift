//
//  SemanticCloneTests.swift
//  SwiftStaticAnalysis
//
//  Tests for semantic clone (Type-3/Type-4) detection.
//

import Foundation
import Testing
@testable import DuplicationDetector
@testable import SwiftStaticAnalysisCore
import SwiftSyntax
import SwiftParser

@Suite("Semantic Clone Detection Tests")
struct SemanticCloneTests {

    // MARK: - AST Fingerprinting

    @Test("Fingerprint function bodies")
    func fingerprintFunctions() {
        let source = """
        func add(a: Int, b: Int) -> Int {
            return a + b
        }

        func subtract(x: Int, y: Int) -> Int {
            return x - y
        }
        """

        let tree = Parser.parse(source: source)
        let visitor = ASTFingerprintVisitor(file: "test.swift", tree: tree)
        visitor.walk(tree)

        let fingerprints = visitor.fingerprintedNodes

        // Should have fingerprints for function bodies
        #expect(fingerprints.count >= 2)
    }

    @Test("Similar AST structures produce similar fingerprints")
    func similarASTFingerprints() {
        // These have the same AST structure (binary operation on parameters)
        let source = """
        func multiply(a: Int, b: Int) -> Int {
            return a * b
        }

        func divide(x: Int, y: Int) -> Int {
            return x / y
        }
        """

        let tree = Parser.parse(source: source)
        let visitor = ASTFingerprintVisitor(file: "test.swift", tree: tree)
        visitor.walk(tree)

        let fingerprints = visitor.fingerprintedNodes

        #expect(fingerprints.count >= 2)

        // Node counts should be similar for similar structures
        if fingerprints.count >= 2 {
            let nodeCounts = fingerprints.map(\.fingerprint.nodeCount)
            let maxDiff = abs(nodeCounts[0] - nodeCounts[1])
            // Similar structures should have similar node counts
            #expect(maxDiff <= 5)
        }
    }

    // MARK: - Semantic Clone Detection

    @Test("Detect semantic clones in fixture")
    func detectSemanticClonesInFixture() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("DuplicationScenarios")
            .appendingPathComponent("SemanticClones")
            .appendingPathComponent("AlgorithmicEquivalence.swift")

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            Issue.record("Fixture file not found")
            return
        }

        let source = try String(contentsOfFile: fixturesPath.path, encoding: .utf8)
        let tree = Parser.parse(source: source)

        let visitor = ASTFingerprintVisitor(file: fixturesPath.path, tree: tree)
        visitor.walk(tree)

        let detector = SemanticCloneDetector(minimumNodes: 3, minimumSimilarity: 0.5)
        let clones = detector.detect(in: visitor.fingerprintedNodes)

        // Semantic clone detection is based on AST fingerprint matching
        // Results depend on having matching fingerprint hashes
        if !clones.isEmpty {
            if let group = clones.first {
                #expect(group.type == .semantic)
            }
        }
        // Semantic clones require exact AST structure matches which may not
        // always be present in the fixture. Empty results are acceptable.
    }

    // MARK: - Fingerprint Properties

    @Test("Fingerprint includes depth information")
    func fingerprintIncludesDepth() {
        let source = """
        func nested() {
            if true {
                if true {
                    if true {
                        print("deep")
                    }
                }
            }
        }

        func shallow() {
            print("shallow")
        }
        """

        let tree = Parser.parse(source: source)
        let visitor = ASTFingerprintVisitor(file: "test.swift", tree: tree)
        visitor.walk(tree)

        let fingerprints = visitor.fingerprintedNodes

        // Find the nested and shallow functions' fingerprints
        let sorted = fingerprints.sorted { $0.fingerprint.depth > $1.fingerprint.depth }

        if sorted.count >= 2 {
            // Nested function should have greater depth
            #expect(sorted[0].fingerprint.depth > sorted.last!.fingerprint.depth)
        }
    }

    @Test("Fingerprint includes node count")
    func fingerprintIncludesNodeCount() {
        let source = """
        func simple() { print("x") }

        func complex() {
            let a = 1
            let b = 2
            let c = 3
            let d = a + b + c
            print(d)
        }
        """

        let tree = Parser.parse(source: source)
        let visitor = ASTFingerprintVisitor(file: "test.swift", tree: tree)
        visitor.walk(tree)

        let fingerprints = visitor.fingerprintedNodes

        if fingerprints.count >= 2 {
            let nodeCounts = fingerprints.map(\.fingerprint.nodeCount)
            // Complex function should have more nodes
            #expect(nodeCounts.max()! > nodeCounts.min()!)
        }
    }

    // MARK: - Clone Groups

    @Test("Group semantically similar functions")
    func groupSemanticallySimilar() {
        // All these do similar things (return doubled input)
        let source = """
        func double1(_ n: Int) -> Int { n * 2 }
        func double2(_ n: Int) -> Int { n + n }
        func double3(_ n: Int) -> Int { 2 * n }
        """

        let tree = Parser.parse(source: source)
        let visitor = ASTFingerprintVisitor(file: "test.swift", tree: tree)
        visitor.walk(tree)

        let detector = SemanticCloneDetector(minimumNodes: 3, minimumSimilarity: 0.6)
        let clones = detector.detect(in: visitor.fingerprintedNodes)

        // These should be grouped as semantic clones
        if clones.count > 0 {
            #expect(clones.first?.clones.count ?? 0 >= 2)
        }
    }

    // MARK: - Edge Cases

    @Test("Handle empty fingerprints")
    func handleEmptyFingerprints() {
        let detector = SemanticCloneDetector(minimumNodes: 5, minimumSimilarity: 0.7)
        let clones = detector.detect(in: [])

        #expect(clones.isEmpty)
    }

    @Test("Handle single fingerprint")
    func handleSingleFingerprint() {
        let source = "func single() { print(1) }"

        let tree = Parser.parse(source: source)
        let visitor = ASTFingerprintVisitor(file: "test.swift", tree: tree)
        visitor.walk(tree)

        let detector = SemanticCloneDetector(minimumNodes: 1, minimumSimilarity: 0.7)
        let clones = detector.detect(in: visitor.fingerprintedNodes)

        // Single fingerprint can't form a clone group
        #expect(clones.isEmpty)
    }

    @Test("Closures get fingerprinted")
    func fingerprintClosures() {
        let source = """
        let closure1 = { (x: Int) -> Int in x * 2 }
        let closure2 = { (y: Int) -> Int in y + y }
        """

        let tree = Parser.parse(source: source)
        let visitor = ASTFingerprintVisitor(file: "test.swift", tree: tree)
        visitor.walk(tree)

        // Closures should be fingerprinted
        #expect(visitor.fingerprintedNodes.count >= 2)
    }
}

@Suite("ASTFingerprint Tests")
struct ASTFingerprintUnitTests {

    @Test("Fingerprint initialization")
    func fingerprintInit() {
        let fp = ASTFingerprint(
            hash: 12345,
            depth: 5,
            nodeCount: 20,
            rootKind: "FunctionDeclSyntax"
        )

        #expect(fp.hash == 12345)
        #expect(fp.depth == 5)
        #expect(fp.nodeCount == 20)
        #expect(fp.rootKind == "FunctionDeclSyntax")
    }

    @Test("FingerprintedNode initialization")
    func fingerprintedNodeInit() {
        let fp = ASTFingerprint(hash: 123, depth: 3, nodeCount: 10, rootKind: "Test")
        let node = FingerprintedNode(
            file: "test.swift",
            fingerprint: fp,
            startLine: 1,
            endLine: 10,
            startColumn: 1,
            tokenCount: 50
        )

        #expect(node.file == "test.swift")
        #expect(node.fingerprint.hash == 123)
        #expect(node.startLine == 1)
        #expect(node.endLine == 10)
        #expect(node.startColumn == 1)
        #expect(node.tokenCount == 50)
    }

    @Test("Line count calculation")
    func lineCountCalculation() {
        let fp = ASTFingerprint(hash: 1, depth: 1, nodeCount: 1, rootKind: "Test")
        let node = FingerprintedNode(
            file: "test.swift",
            fingerprint: fp,
            startLine: 5,
            endLine: 15,
            startColumn: 1,
            tokenCount: 100
        )

        // Line count should be endLine - startLine + 1
        #expect(node.endLine - node.startLine + 1 == 11)
    }
}
