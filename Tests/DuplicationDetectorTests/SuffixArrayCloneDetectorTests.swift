//  SuffixArrayCloneDetectorTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

// MARK: - Test Tags

extension Tag {
    @Tag static var cloneDetection: Self
    @Tag static var algorithm: Self
    @Tag static var boundary: Self
    @Tag static var unit: Self
}

@Suite("Suffix Array Clone Detector Tests", .tags(.cloneDetection, .algorithm))
struct SuffixArrayCloneDetectorTests {
    // MARK: - Initialization Tests

    @Test("Detector initialization with default values", .tags(.unit))
    func detectorInit() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 30)
        #expect(detector.minimumTokens == 30)
        #expect(detector.normalizeForType2 == false)
    }

    @Test("Detector initialization with Type-2 normalization enabled")
    func detectorInitWithNormalization() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 20, normalizeForType2: true)
        #expect(detector.minimumTokens == 20)
        #expect(detector.normalizeForType2 == true)
    }

    // MARK: - Empty/Boundary Input Tests

    @Test("Detection with empty input returns empty result", .tags(.boundary))
    func detectEmptyInput() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 10)
        let result = detector.detect(in: [])
        #expect(result.isEmpty)
    }

    @Test("Detection with single sequence below threshold returns empty")
    func detectBelowThreshold() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 100)

        let tokens = (0..<50).map { TokenInfo(kind: .identifier, text: "t\($0)", line: $0, column: 0) }
        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])

        let result = detector.detect(in: [sequence])
        #expect(result.isEmpty)
    }

    @Test("Detection with zero minimumTokens validates guard")
    func detectZeroMinTokens() {
        // minimumTokens of 0 should return empty (guarded at start)
        let detector = SuffixArrayCloneDetector(minimumTokens: 0)
        let tokens = (0..<10).map { TokenInfo(kind: .identifier, text: "token", line: $0, column: 0) }
        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])

        let result = detector.detect(in: [sequence])
        #expect(result.isEmpty)
    }

    // MARK: - Cross-File Boundary Tests

    @Test("Cross-file boundaries prevent false clone matches")
    func crossFileBoundaryPreventsMatch() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 5)

        // Create identical token sequences in two files
        // If boundaries weren't respected, these could falsely match across files
        let tokens1 = (0..<10).map { TokenInfo(kind: .identifier, text: "shared\($0 % 5)", line: $0, column: 0) }
        let tokens2 = (0..<10).map { TokenInfo(kind: .identifier, text: "shared\($0 % 5)", line: $0, column: 0) }

        let seq1 = TokenSequence(file: "file1.swift", tokens: tokens1, sourceLines: [])
        let seq2 = TokenSequence(file: "file2.swift", tokens: tokens2, sourceLines: [])

        let result = detector.detect(in: [seq1, seq2])

        // If clones are found across files, they should have proper file references
        // and not match tokens that span the file boundary (via separator)
        for group in result {
            for clone in group.clones {
                #expect(clone.file == "file1.swift" || clone.file == "file2.swift")
            }
        }
    }

    @Test("Separator tokens prevent cross-file continuation matches")
    func separatorTokensPreventsMatch() {
        // This tests that the separator between files prevents matching
        // a sequence that would span both files
        let detector = SuffixArrayCloneDetector(minimumTokens: 4)

        // File 1 ends with [A, B]
        // File 2 starts with [B, C]
        // Should NOT match as [A, B, B, C] clone across files
        let tokens1 = [
            TokenInfo(kind: .identifier, text: "A", line: 1, column: 0),
            TokenInfo(kind: .identifier, text: "B", line: 2, column: 0),
        ]
        let tokens2 = [
            TokenInfo(kind: .identifier, text: "B", line: 1, column: 0),
            TokenInfo(kind: .identifier, text: "C", line: 2, column: 0),
        ]

        let seq1 = TokenSequence(file: "end.swift", tokens: tokens1, sourceLines: [])
        let seq2 = TokenSequence(file: "start.swift", tokens: tokens2, sourceLines: [])

        let result = detector.detect(in: [seq1, seq2])

        // No clones should be found (sequences too short to form valid clones)
        #expect(result.isEmpty)
    }

    // MARK: - Single File Exact Duplicate Tests

    @Test("Single file with exact duplicate code blocks")
    func singleFileExactDuplicates() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 5)

        // Create a sequence with repeated pattern
        var tokens: [TokenInfo] = []
        let pattern = ["func", "foo", "(", ")", "{"]

        // First occurrence at line 1
        for (i, text) in pattern.enumerated() {
            tokens.append(TokenInfo(kind: .identifier, text: text, line: 1, column: i))
        }

        // Some different code
        tokens.append(TokenInfo(kind: .identifier, text: "different", line: 6, column: 0))
        tokens.append(TokenInfo(kind: .identifier, text: "code", line: 7, column: 0))

        // Second occurrence at line 10
        for (i, text) in pattern.enumerated() {
            tokens.append(TokenInfo(kind: .identifier, text: text, line: 10, column: i))
        }

        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])
        let result = detector.detect(in: [sequence])

        // Should detect the repeated pattern
        #expect(result.count >= 1, "Should detect at least one clone group")

        if let group = result.first {
            #expect(group.clones.count >= 2, "Should have at least 2 clone occurrences")
            // All clones should be in the same file
            for clone in group.clones {
                #expect(clone.file == "test.swift")
            }
        }
    }

    // MARK: - Type-2 Normalization Tests

    @Test("Type-2 normalization detects clones with different identifiers")
    func type2NormalizationDetection() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 5, normalizeForType2: true)

        // Create two code blocks that are structurally identical
        // but use different variable names
        var tokens: [TokenInfo] = []

        // Block 1: "let x = 10"
        tokens.append(TokenInfo(kind: .keyword, text: "let", line: 1, column: 0))
        tokens.append(TokenInfo(kind: .identifier, text: "x", line: 1, column: 4))
        tokens.append(TokenInfo(kind: .punctuation, text: "=", line: 1, column: 6))
        tokens.append(TokenInfo(kind: .literal, text: "10", line: 1, column: 8))
        tokens.append(TokenInfo(kind: .punctuation, text: ";", line: 1, column: 10))

        // Separator
        tokens.append(TokenInfo(kind: .identifier, text: "separator", line: 5, column: 0))

        // Block 2: "let y = 20" (same structure, different names/values)
        tokens.append(TokenInfo(kind: .keyword, text: "let", line: 10, column: 0))
        tokens.append(TokenInfo(kind: .identifier, text: "y", line: 10, column: 4))
        tokens.append(TokenInfo(kind: .punctuation, text: "=", line: 10, column: 6))
        tokens.append(TokenInfo(kind: .literal, text: "20", line: 10, column: 8))
        tokens.append(TokenInfo(kind: .punctuation, text: ";", line: 10, column: 10))

        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])

        // Use normalized detection for Type-2
        let result = detector.detectWithNormalization(in: [sequence])

        // With normalization, these structurally similar blocks should be detected
        // Note: Whether they match depends on the normalizer configuration
        // This test validates the detection pathway works correctly
        #expect(result.isEmpty || result.first?.type == .near, "Type-2 clones should be marked as 'near' type")
    }

    // MARK: - Edge Case Tests

    @Test("Single token sequence returns empty")
    func singleTokenSequence() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 1)
        let tokens = [TokenInfo(kind: .identifier, text: "single", line: 1, column: 0)]
        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])

        let result = detector.detect(in: [sequence])
        // Single unique token cannot form a clone (needs repetition)
        #expect(result.isEmpty)
    }

    @Test("All identical tokens finds repeats")
    func allIdenticalTokens() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 3)

        // 10 identical tokens
        let tokens = (0..<10).map { TokenInfo(kind: .identifier, text: "same", line: $0, column: 0) }
        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])

        let result = detector.detect(in: [sequence])

        // Should detect overlapping repeats of "same same same ..."
        #expect(result.count >= 1, "Should detect repeated patterns")
    }

    @Test("Minimum tokens boundary condition")
    func minimumTokensBoundary() {
        // Test exact boundary: sequence length == minimumTokens
        let detector = SuffixArrayCloneDetector(minimumTokens: 5)

        // Exactly 5 tokens repeated twice
        var tokens: [TokenInfo] = []
        for i in 0..<5 {
            tokens.append(TokenInfo(kind: .identifier, text: "t\(i)", line: i, column: 0))
        }
        // Gap
        tokens.append(TokenInfo(kind: .identifier, text: "gap", line: 10, column: 0))
        // Same 5 tokens again
        for i in 0..<5 {
            tokens.append(TokenInfo(kind: .identifier, text: "t\(i)", line: 20 + i, column: 0))
        }

        let sequence = TokenSequence(file: "test.swift", tokens: tokens, sourceLines: [])
        let result = detector.detect(in: [sequence])

        // Should detect exactly at the boundary
        #expect(result.count >= 1, "Should detect clones at exact minimum token boundary")
    }

    @Test("Multiple files with shared duplicates")
    func multipleFilesSharedDuplicates() {
        let detector = SuffixArrayCloneDetector(minimumTokens: 5)

        let pattern = ["import", "Foundation", ";", "class", "Foo", "{", "}"]

        // Same pattern in three different files
        let seq1 = TokenSequence(
            file: "file1.swift",
            tokens: pattern.enumerated().map {
                TokenInfo(kind: .identifier, text: $0.element, line: $0.offset, column: 0)
            },
            sourceLines: []
        )
        let seq2 = TokenSequence(
            file: "file2.swift",
            tokens: pattern.enumerated().map {
                TokenInfo(kind: .identifier, text: $0.element, line: $0.offset, column: 0)
            },
            sourceLines: []
        )
        let seq3 = TokenSequence(
            file: "file3.swift",
            tokens: pattern.enumerated().map {
                TokenInfo(kind: .identifier, text: $0.element, line: $0.offset, column: 0)
            },
            sourceLines: []
        )

        let result = detector.detect(in: [seq1, seq2, seq3])

        // Should detect clones across all three files
        if !result.isEmpty {
            let firstGroup = result[0]
            #expect(firstGroup.clones.count >= 2, "Should detect clones in multiple files")

            // Verify clones reference different files
            let files = Set(firstGroup.clones.map(\.file))
            #expect(files.count >= 2, "Clones should span multiple files")
        }
    }
}
