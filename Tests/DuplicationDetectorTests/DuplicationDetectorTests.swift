//
//  DuplicationDetectorTests.swift
//  SwiftStaticAnalysis
//

import SwiftParser
import SwiftSyntax
import Testing
@testable import DuplicationDetector
@testable import SwiftStaticAnalysisCore

// MARK: - DuplicationDetectorTests

@Suite("DuplicationDetector Tests")
struct DuplicationDetectorTests {
    @Test("CloneType raw values")
    func cloneTypeRawValues() {
        #expect(CloneType.exact.rawValue == "exact")
        #expect(CloneType.near.rawValue == "near")
        #expect(CloneType.semantic.rawValue == "semantic")
    }

    @Test("Clone initialization")
    func cloneInit() {
        let clone = Clone(
            file: "test.swift",
            startLine: 10,
            endLine: 20,
            tokenCount: 50,
            codeSnippet: "func test() { }",
        )

        #expect(clone.file == "test.swift")
        #expect(clone.startLine == 10)
        #expect(clone.endLine == 20)
        #expect(clone.tokenCount == 50)
    }

    @Test("CloneGroup metrics")
    func cloneGroupMetrics() {
        let clones = [
            Clone(file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, codeSnippet: ""),
            Clone(file: "b.swift", startLine: 5, endLine: 14, tokenCount: 50, codeSnippet: ""),
        ]

        let group = CloneGroup(
            type: .exact,
            clones: clones,
            similarity: 1.0,
            fingerprint: "abc123",
        )

        #expect(group.occurrences == 2)
        #expect(group.duplicatedLines == 20) // 10 + 10
    }

    @Test("DuplicationConfiguration defaults")
    func configurationDefaults() {
        let config = DuplicationConfiguration.default

        #expect(config.minimumTokens == 50)
        #expect(config.cloneTypes == [.exact])
        #expect(config.minimumSimilarity == 0.8)
    }

    @Test("DuplicationDetector initialization")
    func detectorInit() {
        let config = DuplicationConfiguration(
            minimumTokens: 30,
            cloneTypes: [.exact, .near],
        )

        let detector = DuplicationDetector(configuration: config)

        #expect(detector.configuration.minimumTokens == 30)
        #expect(detector.configuration.cloneTypes.contains(.exact))
        #expect(detector.configuration.cloneTypes.contains(.near))
    }

    @Test("DuplicationReport metrics")
    func reportMetrics() {
        let clones = [
            Clone(file: "a.swift", startLine: 1, endLine: 10, tokenCount: 50, codeSnippet: ""),
            Clone(file: "b.swift", startLine: 1, endLine: 10, tokenCount: 50, codeSnippet: ""),
        ]

        let group = CloneGroup(type: .exact, clones: clones, similarity: 1.0, fingerprint: "x")

        let report = DuplicationReport(
            filesAnalyzed: 10,
            totalLines: 1000,
            cloneGroups: [group],
        )

        #expect(report.duplicatedLines == 20)
        #expect(report.duplicationPercentage == 2.0)
    }
}

// MARK: - TokenExtractionTests

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

// MARK: - TokenNormalizerTests

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

// MARK: - ExactCloneDetectorTests

@Suite("Exact Clone Detector Tests")
struct ExactCloneDetectorTests {
    @Test("ExactCloneDetector initialization")
    func initialization() {
        let detector = ExactCloneDetector(minimumTokens: 30)
        #expect(detector.minimumTokens == 30)
    }

    @Test("Empty sequence returns no clones")
    func emptySequenceNoClones() {
        let detector = ExactCloneDetector(minimumTokens: 5)
        let clones = detector.detect(in: [])
        #expect(clones.isEmpty)
    }
}

// MARK: - NearCloneDetectorTests

@Suite("Near Clone Detector Tests")
struct NearCloneDetectorTests {
    @Test("NearCloneDetector initialization")
    func initialization() {
        let detector = NearCloneDetector(minimumTokens: 25, minimumSimilarity: 0.9)
        #expect(detector.minimumTokens == 25)
        #expect(detector.minimumSimilarity == 0.9)
    }
}

// MARK: - SemanticCloneDetectorTests

@Suite("Semantic Clone Detector Tests")
struct SemanticCloneDetectorTests {
    @Test("SemanticCloneDetector initialization")
    func initialization() {
        let detector = SemanticCloneDetector(minimumNodes: 15, minimumSimilarity: 0.75)
        #expect(detector.minimumNodes == 15)
        #expect(detector.minimumSimilarity == 0.75)
    }
}

// MARK: - ASTFingerprintTests

@Suite("AST Fingerprint Tests")
struct ASTFingerprintTests {
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
