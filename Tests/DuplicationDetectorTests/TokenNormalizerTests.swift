//
//  TokenNormalizerTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify TokenNormalizer replaces identifiers with placeholder
//  - Test literal normalization
//  - Validate preserved identifiers (standard library types) are not normalized
//
//  ## Coverage
//  - TokenNormalizer.normalize(): identifier replacement
//  - TokenNormalizer: literal normalization with number placeholder
//  - Preserved identifiers (String, Int, etc.) remain unchanged
//

import SwiftParser
import Testing

@testable import DuplicationDetector
@testable import SwiftStaticAnalysisCore

@Suite("Token Normalizer Tests")
struct TokenNormalizerTests {
    @Test("Normalizer replaces identifiers with placeholder")
    func normalizeIdentifiers() {
        let source = "let userName = value"
        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        let normalizer = TokenNormalizer.default
        let normalized = normalizer.normalize(sequence)

        let normalizedTexts = normalized.tokens.map(\.normalized)

        // Identifiers should be normalized to $ID (except preserved ones)
        #expect(normalizedTexts.contains(TokenNormalizer.identifierPlaceholder))
        // Keywords should remain unchanged
        #expect(normalizedTexts.contains("let"))
    }

    @Test("Normalizer replaces literals with placeholder")
    func normalizeLiterals() {
        let source = "let x = 42"
        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        let normalizer = TokenNormalizer(normalizeLiterals: true)
        let normalized = normalizer.normalize(sequence)

        let normalizedTexts = normalized.tokens.map(\.normalized)

        // Numeric literal should be normalized
        #expect(normalizedTexts.contains(TokenNormalizer.numberPlaceholder))
    }

    @Test("Preserved identifiers are not normalized")
    func preservedIdentifiers() {
        let source = "let s: String = value"
        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        let normalizer = TokenNormalizer.default
        let normalized = normalizer.normalize(sequence)

        let normalizedTexts = normalized.tokens.map(\.normalized)

        // String is a preserved identifier
        #expect(normalizedTexts.contains("String"))
    }
}
