//  LSHPipelineTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("LSH Pipeline Tests")
struct LSHPipelineTests {
    @Test("Find similar pairs in documents")
    func findSimilarPairs() {
        let pipeline = LSHPipeline(numHashes: 128, threshold: 0.5)
        let shingleGen = ShingleGenerator(shingleSize: 3, normalize: false)

        // Create similar token sequences
        let tokens1 = ["func", "foo", "(", "x", ")", "{", "return", "x", "+", "1", "}"]
        let tokens2 = ["func", "bar", "(", "y", ")", "{", "return", "y", "+", "1", "}"]
        let tokens3 = ["class", "Widget", "{", "var", "size", ":", "Int", "}"]

        let shingles1 = shingleGen.generate(tokens: tokens1, kinds: nil)
        let shingles2 = shingleGen.generate(tokens: tokens2, kinds: nil)
        let shingles3 = shingleGen.generate(tokens: tokens3, kinds: nil)

        let doc1 = ShingledDocument(
            file: "file1.swift", startLine: 1, endLine: 1, tokenCount: tokens1.count,
            shingleHashes: Set(shingles1.map(\.hash)), shingles: shingles1, id: 1,
        )
        let doc2 = ShingledDocument(
            file: "file2.swift", startLine: 1, endLine: 1, tokenCount: tokens2.count,
            shingleHashes: Set(shingles2.map(\.hash)), shingles: shingles2, id: 2,
        )
        let doc3 = ShingledDocument(
            file: "file3.swift", startLine: 1, endLine: 1, tokenCount: tokens3.count,
            shingleHashes: Set(shingles3.map(\.hash)), shingles: shingles3, id: 3,
        )

        let pairs = pipeline.findSimilarPairs([doc1, doc2, doc3], verifyWithExact: true)

        // All returned pairs should meet the threshold
        #expect(pairs.allSatisfy { $0.similarity >= 0.5 })
    }
}
