//
//  MinHashIntegrationTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify end-to-end MinHash-based clone detection
//  - Test LSH finds near duplicates
//
//  ## Coverage
//  - End-to-end clone detection with realistic code patterns
//  - LSH index finding near-duplicate documents
//

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("MinHash Integration Tests")
struct MinHashIntegrationTests {
    @Test("End-to-end clone detection")
    func endToEndCloneDetection() {
        // Create a realistic scenario with similar code blocks
        let shingleGen = ShingleGenerator(shingleSize: 4, normalize: true)
        let minHashGen = MinHashGenerator(numHashes: 128)

        // Simulate two similar functions
        let funcTokens1 = [
            "func", "calculate", "(", "value", ":", "Int", ")", "->", "Int", "{",
            "let", "result", "=", "value", "*", "2",
            "return", "result",
            "}",
        ]
        let funcKinds1: [TokenKind] = [
            .keyword, .identifier, .punctuation, .identifier, .punctuation, .keyword, .punctuation, .operator, .keyword,
            .punctuation,
            .keyword, .identifier, .operator, .identifier, .operator, .literal,
            .keyword, .identifier,
            .punctuation,
        ]

        let funcTokens2 = [
            "func", "compute", "(", "input", ":", "Int", ")", "->", "Int", "{",
            "let", "output", "=", "input", "*", "3",
            "return", "output",
            "}",
        ]
        let funcKinds2: [TokenKind] = [
            .keyword, .identifier, .punctuation, .identifier, .punctuation, .keyword, .punctuation, .operator, .keyword,
            .punctuation,
            .keyword, .identifier, .operator, .identifier, .operator, .literal,
            .keyword, .identifier,
            .punctuation,
        ]

        let shingles1 = shingleGen.generate(tokens: funcTokens1, kinds: funcKinds1)
        let shingles2 = shingleGen.generate(tokens: funcTokens2, kinds: funcKinds2)

        let hashes1 = Set(shingles1.map(\.hash))
        let hashes2 = Set(shingles2.map(\.hash))

        // With normalization, these should be very similar
        let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)
        #expect(exact > 0.7)

        // MinHash estimation should be close
        let sig1 = minHashGen.computeSignature(for: hashes1, documentId: 0)
        let sig2 = minHashGen.computeSignature(for: hashes2, documentId: 1)
        let estimated = sig1.estimateSimilarity(with: sig2)

        #expect(abs(estimated - exact) < 0.15)
    }

    @Test("LSH finds near duplicates")
    func lshFindsNearDuplicates() {
        let shingleGen = ShingleGenerator(shingleSize: 3, normalize: false)
        let minHashGen = MinHashGenerator(numHashes: 64)

        // Create 10 documents, 3 of which are near-duplicates
        var documents: [ShingledDocument] = []

        for i in 0..<10 {
            let tokens: [String] =
                if i < 3 {
                    // Near-duplicates: same base with small variation
                    ["common", "tokens", "here", "variant\(i)"]
                } else {
                    // Unique documents
                    ["unique", "document", "number", "\(i)", "extra\(i)"]
                }

            let shingles = shingleGen.generate(tokens: tokens, kinds: nil)
            documents.append(
                ShingledDocument(
                    file: "file\(i).swift",
                    startLine: 1, endLine: 1,
                    tokenCount: tokens.count,
                    shingleHashes: Set(shingles.map(\.hash)),
                    shingles: shingles,
                    id: i,
                ))
        }

        // Build LSH index
        let signatures = minHashGen.computeSignatures(for: documents)
        var index = LSHIndex(signatureSize: 64, threshold: 0.3)
        index.insert(signatures)

        // Find candidate pairs
        let pairs = index.findCandidatePairs()

        // Should find pairs among documents 0, 1, 2
        let nearDupPairs = pairs.filter { $0.id1 < 3 && $0.id2 < 3 }
        #expect(!nearDupPairs.isEmpty)
    }
}
