//  ASTFingerprintTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import DuplicationDetector

@Suite("AST Fingerprint Tests")
struct ASTFingerprintTests {
    @Test
    func `FingerprintHasher hash output stays in the Mersenne-61 prime range`() {
        // Post-0.3.0-α the AST fingerprint hasher reduces via M_61 instead
        // of `% 1_000_000_007` (a 30-bit prime that produced ~50%
        // collisions at N≈50_000). Probe a deterministic set of strings
        // and check (a) every output is < 2^61 − 1, (b) distinct inputs
        // produce distinct outputs (no trivial pigeon-holing into the
        // pre-0.3 30-bit space).
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
        // With M_61 a 10 000-sample set should collide essentially
        // never. The pre-0.3 30-bit modulus collided ~hundreds of
        // times at this volume. We assert > 9 990 distinct (allow a
        // tiny margin for unlucky inputs); empirically observe 10 000.
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
