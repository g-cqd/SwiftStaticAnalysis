//  ASTFingerprintTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import DuplicationDetector

@Suite("AST Fingerprint Tests")
struct ASTFingerprintTests {
    @Test
    func `FingerprintHasher hash output stays in the Mersenne-61 prime range`() {
        // Probe a deterministic 10 000-sample set and check (a) every
        // output is < 2^61 − 1 (the M_61 reduction envelope), (b) the
        // collision rate is essentially zero (>9 990 / 10 000 distinct,
        // allowing a tiny margin for unlucky inputs).
        let mersenne61: UInt64 = (1 &<< 61) &- 1
        var outputs = Set<UInt64>()
        for index in 0..<10_000 {
            var hasher = FingerprintHasher()
            hasher.hashString("Decl:Function:foo_\(index)")
            hasher.hashString("Stmt:Return:value_\(index % 7)")
            let value = hasher.finalHash()
            #expect(value < mersenne61, "hash \(value) exceeded M_61 envelope")
            outputs.insert(value)
        }
        #expect(outputs.count > 9_990, "collision-heavy hash distribution: \(outputs.count) distinct of 10 000")
    }

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
