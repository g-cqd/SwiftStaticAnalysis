//  FastSimilarityCheckerTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("Fast Similarity Checker Tests")
struct FastSimilarityCheckerTests {
    @Test("Identical sequences have similarity 1.0")
    func identicalSequences() {
        let checker = FastSimilarityChecker(shingleSize: 3, numHashes: 128)
        let tokens = ["func", "foo", "let", "var", "if", "else"]
        let kinds: [TokenKind] = [.keyword, .identifier, .keyword, .keyword, .keyword, .keyword]

        let similarity = checker.exactSimilarity(tokens, kinds1: kinds, tokens, kinds2: kinds)

        #expect(abs(similarity - 1.0) < 0.001)
    }

    @Test("Completely different code structures have low similarity")
    func completelyDifferent() {
        let checker = FastSimilarityChecker(shingleSize: 3, numHashes: 128)
        // Different code structures (keywords matter, identifiers get normalized)
        let tokens1 = ["func", "foo", "(", ")", "{", "}"]
        let kinds1: [TokenKind] = [.keyword, .identifier, .punctuation, .punctuation, .punctuation, .punctuation]
        let tokens2 = ["class", "Bar", ":", "Protocol", "{", "}"]
        let kinds2: [TokenKind] = [.keyword, .identifier, .punctuation, .identifier, .punctuation, .punctuation]

        let similarity = checker.exactSimilarity(tokens1, kinds1: kinds1, tokens2, kinds2: kinds2)

        // Different keywords should result in low similarity
        #expect(similarity < 0.5)
    }

    @Test("Similar code structures with different names have high similarity")
    func similarStructures() {
        let checker = FastSimilarityChecker(shingleSize: 2, numHashes: 128)
        // Same structure, different identifier names (should normalize to same)
        let tokens1 = ["func", "calculate", "(", "value", ")", "{", "return", "value", "}"]
        let kinds1: [TokenKind] = [
            .keyword,
            .identifier,
            .punctuation,
            .identifier,
            .punctuation,
            .punctuation,
            .keyword,
            .identifier,
            .punctuation,
        ]
        let tokens2 = ["func", "compute", "(", "input", ")", "{", "return", "input", "}"]
        let kinds2: [TokenKind] = [
            .keyword,
            .identifier,
            .punctuation,
            .identifier,
            .punctuation,
            .punctuation,
            .keyword,
            .identifier,
            .punctuation,
        ]

        let similarity = checker.exactSimilarity(tokens1, kinds1: kinds1, tokens2, kinds2: kinds2)

        // With normalization, these should be highly similar
        #expect(similarity > 0.8)
    }

    @Test("Estimated vs exact similarity")
    func estimatedVsExact() {
        let checker = FastSimilarityChecker(shingleSize: 3, numHashes: 256)
        let tokens1 = [
            "func", "a", "(", ")", "{", "let", "x", "=", "1", "}",
            "func", "b", "(", ")", "{", "let", "y", "=", "2", "}",
        ]
        let tokens2 = [
            "func", "c", "(", ")", "{", "let", "z", "=", "3", "}",
            "class", "D", "{", "var", "w", ":", "Int", "=", "4", "}",
        ]
        let kinds1: [TokenKind] = [
            .keyword,
            .identifier,
            .punctuation,
            .punctuation,
            .punctuation,
            .keyword,
            .identifier,
            .operator,
            .literal,
            .punctuation,
            .keyword,
            .identifier,
            .punctuation,
            .punctuation,
            .punctuation,
            .keyword,
            .identifier,
            .operator,
            .literal,
            .punctuation,
        ]
        let kinds2: [TokenKind] = [
            .keyword,
            .identifier,
            .punctuation,
            .punctuation,
            .punctuation,
            .keyword,
            .identifier,
            .operator,
            .literal,
            .punctuation,
            .keyword,
            .identifier,
            .punctuation,
            .keyword,
            .identifier,
            .punctuation,
            .keyword,
            .operator,
            .literal,
            .punctuation,
        ]

        let estimated = checker.estimateSimilarity(tokens1, kinds1: kinds1, tokens2, kinds2: kinds2)
        let exact = checker.exactSimilarity(tokens1, kinds1: kinds1, tokens2, kinds2: kinds2)

        #expect(abs(estimated - exact) < 0.15)
    }
}
