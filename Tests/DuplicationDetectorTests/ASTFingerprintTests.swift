//
//  ASTFingerprintTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify ASTFingerprint initialization and properties
//  - Test FingerprintedNode initialization
//
//  ## Coverage
//  - ASTFingerprint: hash, depth, nodeCount, rootKind
//  - FingerprintedNode: file, fingerprint, line range, tokenCount
//
//  ## Gaps
//  - Missing: fingerprint computation from actual AST nodes
//  - Missing: fingerprint comparison/matching tests
//

import Testing

@testable import DuplicationDetector

@Suite("AST Fingerprint Tests")
struct ASTFingerprintTests {
    @Test("ASTFingerprint initialization")
    func fingerprintInit() {
        let fp = ASTFingerprint(
            hash: 12345,
            depth: 5,
            nodeCount: 20,
            rootKind: "CodeBlockSyntax",
        )

        #expect(fp.hash == 12345)
        #expect(fp.depth == 5)
        #expect(fp.nodeCount == 20)
        #expect(fp.rootKind == "CodeBlockSyntax")
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
            tokenCount: 50,
        )

        #expect(node.file == "test.swift")
        #expect(node.fingerprint.hash == 123)
        #expect(node.startLine == 1)
        #expect(node.endLine == 10)
    }
}
