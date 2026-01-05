//  SuffixArrayIntegrationTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("Suffix Array Integration Tests")
struct SuffixArrayIntegrationTests {
    @Test("End-to-end clone detection")
    func endToEndCloneDetection() {
        // Create two token sequences with a shared pattern
        let sharedPattern = (0..<20).map { TokenInfo(kind: .identifier, text: "shared\($0)", line: $0, column: 0) }

        var tokens1 = [TokenInfo(kind: .identifier, text: "unique1", line: 0, column: 0)]
        tokens1.append(contentsOf: sharedPattern)
        tokens1.append(TokenInfo(kind: .identifier, text: "end1", line: 21, column: 0))

        var tokens2 = [TokenInfo(kind: .identifier, text: "unique2", line: 0, column: 0)]
        tokens2.append(contentsOf: sharedPattern)
        tokens2.append(TokenInfo(kind: .identifier, text: "end2", line: 21, column: 0))

        let seq1 = TokenSequence(file: "file1.swift", tokens: tokens1, sourceLines: [])
        let seq2 = TokenSequence(file: "file2.swift", tokens: tokens2, sourceLines: [])

        let detector = SuffixArrayCloneDetector(minimumTokens: 10)
        let clones = detector.detect(in: [seq1, seq2])

        // Should find at least one clone group
        #expect(!clones.isEmpty)

        // The clone should span the shared pattern
        if let group = clones.first {
            #expect(group.type == CloneType.exact)
            #expect(group.clones.count >= 2)
        }
    }

    @Test("Large scale clone detection performance")
    func largeScalePerformance() {
        // Create 10 sequences with some repeated patterns
        var sequences: [TokenSequence] = []

        for fileIdx in 0..<10 {
            var tokens: [TokenInfo] = []

            // Add some unique tokens
            for i in 0..<100 {
                tokens.append(
                    TokenInfo(
                        kind: .identifier,
                        text: "file\(fileIdx)_token\(i)",
                        line: i,
                        column: 0,
                    ))
            }

            // Add a shared pattern (same across all files)
            for i in 0..<50 {
                tokens.append(
                    TokenInfo(
                        kind: .identifier,
                        text: "shared_token\(i)",
                        line: 100 + i,
                        column: 0,
                    ))
            }

            sequences.append(
                TokenSequence(
                    file: "file\(fileIdx).swift",
                    tokens: tokens,
                    sourceLines: [],
                ))
        }

        let detector = SuffixArrayCloneDetector(minimumTokens: 20)

        // This should complete quickly even with large input
        let clones = detector.detect(in: sequences)

        // Should find clones of the shared pattern
        #expect(!clones.isEmpty)
    }
}
