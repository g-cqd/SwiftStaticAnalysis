//  TokenExtractionTests.swift
//  SwiftStaticAnalysis
//  MIT License

import SwiftParser
import Testing

@testable import DuplicationDetector
@testable import SwiftStaticAnalysisCore

@Suite("Token Extraction Tests")
struct TokenExtractionTests {
    @Test("TokenSequenceExtractor extracts tokens from source")
    func extractTokens() {
        let source = """
            func hello() {
                print("world")
            }
            """

        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        #expect(sequence.file == "test.swift")
        #expect(!sequence.tokens.isEmpty)

        // Should have func, hello, (, ), {, print, (, "world", ), }
        let tokenTexts = sequence.tokens.map(\.text)
        #expect(tokenTexts.contains("func"))
        #expect(tokenTexts.contains("hello"))
        #expect(tokenTexts.contains("print"))
    }

    @Test("TokenKind classification")
    func tokenKindClassification() {
        let source = "let x = 42 + y"
        let tree = Parser.parse(source: source)
        let extractor = TokenSequenceExtractor()
        let sequence = extractor.extract(from: tree, file: "test.swift", source: source)

        let kinds = Dictionary(grouping: sequence.tokens) { $0.kind }

        #expect(kinds[.keyword]?.contains { $0.text == "let" } == true)
        #expect(kinds[.identifier]?.contains { $0.text == "x" } == true)
        #expect(kinds[.literal]?.contains { $0.text == "42" } == true)
        #expect(kinds[.operator]?.contains { $0.text == "+" } == true)
    }
}
