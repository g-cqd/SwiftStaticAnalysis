//  MinHashCloneDetectorTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("MinHash Clone Detector Tests")
struct MinHashCloneDetectorTests {
    @Test("Detector initialization")
    func detectorInitialization() {
        let detector = MinHashCloneDetector(
            minimumTokens: 30,
            shingleSize: 4,
            numHashes: 64,
            minimumSimilarity: 0.6,
        )

        #expect(detector.minimumTokens == 30)
        #expect(detector.shingleSize == 4)
        #expect(detector.numHashes == 64)
        #expect(detector.minimumSimilarity == 0.6)
    }

    @Test("Empty input returns no clones")
    func emptyInput() {
        let detector = MinHashCloneDetector()
        let clones = detector.detect(in: [])

        #expect(clones.isEmpty)
    }

    @Test("Detect with token sequences")
    func detectWithTokenSequences() {
        let detector = MinHashCloneDetector(
            minimumTokens: 10,
            shingleSize: 3,
            numHashes: 64,
            minimumSimilarity: 0.4,
        )

        // Create token sequences that should be similar
        let tokens1: [TokenInfo] = (0..<20).map { i in
            TokenInfo(kind: .identifier, text: "token\(i % 5)", line: i / 5 + 1, column: 0)
        }
        let tokens2: [TokenInfo] = (0..<20).map { i in
            TokenInfo(kind: .identifier, text: "token\(i % 5)", line: i / 5 + 1, column: 0)
        }

        let seq1 = TokenSequence(file: "file1.swift", tokens: tokens1, sourceLines: [""])
        let seq2 = TokenSequence(file: "file2.swift", tokens: tokens2, sourceLines: [""])

        let clones = detector.detect(in: [seq1, seq2])

        // All found clones should meet the similarity threshold
        #expect(clones.allSatisfy { $0.similarity >= 0.4 })
    }
}
