//
//  MinHashTests.swift
//  SwiftStaticAnalysis
//
//  Comprehensive tests for MinHash, LSH, and shingle-based clone detection.
//

@testable import DuplicationDetector
import Foundation
import Testing

// MARK: - ShingleGeneratorTests

@Suite("Shingle Generator Tests")
struct ShingleGeneratorTests {
    @Test("Basic shingle generation")
    func basicShingleGeneration() {
        let generator = ShingleGenerator(shingleSize: 3, normalize: false)
        let tokens = ["a", "b", "c", "d", "e"]
        let shingles = generator.generate(tokens: tokens, kinds: nil)

        #expect(shingles.count == 3) // 5 tokens - 3 + 1 = 3 shingles
        #expect(shingles[0].tokens == ["a", "b", "c"])
        #expect(shingles[1].tokens == ["b", "c", "d"])
        #expect(shingles[2].tokens == ["c", "d", "e"])
    }

    @Test("Shingle positions are correct")
    func shinglePositions() {
        let generator = ShingleGenerator(shingleSize: 2, normalize: false)
        let tokens = ["x", "y", "z", "w"]
        let shingles = generator.generate(tokens: tokens, kinds: nil)

        #expect(shingles.count == 3)
        #expect(shingles[0].position == 0)
        #expect(shingles[1].position == 1)
        #expect(shingles[2].position == 2)
    }

    @Test("Normalization of identifiers")
    func normalizationOfIdentifiers() {
        let generator = ShingleGenerator(shingleSize: 2, normalize: true)
        let tokens1 = ["func", "foo", "(", "bar", ")"]
        let kinds1: [TokenKind] = [.keyword, .identifier, .punctuation, .identifier, .punctuation]
        let tokens2 = ["func", "baz", "(", "qux", ")"]
        let kinds2: [TokenKind] = [.keyword, .identifier, .punctuation, .identifier, .punctuation]

        let shingles1 = generator.generate(tokens: tokens1, kinds: kinds1)
        let shingles2 = generator.generate(tokens: tokens2, kinds: kinds2)

        // After normalization, both should produce same shingle hashes
        let hashes1 = Set(shingles1.map(\.hash))
        let hashes2 = Set(shingles2.map(\.hash))

        #expect(hashes1 == hashes2)
    }

    @Test("Normalization of literals")
    func normalizationOfLiterals() {
        let generator = ShingleGenerator(shingleSize: 2, normalize: true)
        let tokens1 = ["return", "42"]
        let kinds1: [TokenKind] = [.keyword, .literal]
        let tokens2 = ["return", "100"]
        let kinds2: [TokenKind] = [.keyword, .literal]

        let shingles1 = generator.generate(tokens: tokens1, kinds: kinds1)
        let shingles2 = generator.generate(tokens: tokens2, kinds: kinds2)

        #expect(shingles1.count == 1)
        #expect(shingles2.count == 1)
        #expect(shingles1[0].hash == shingles2[0].hash)
    }

    @Test("Empty input returns empty shingles")
    func emptyInput() {
        let generator = ShingleGenerator(shingleSize: 3, normalize: false)
        let shingles = generator.generate(tokens: [], kinds: nil)

        #expect(shingles.isEmpty)
    }

    @Test("Input smaller than shingle size returns empty")
    func inputSmallerThanShingleSize() {
        let generator = ShingleGenerator(shingleSize: 5, normalize: false)
        let shingles = generator.generate(tokens: ["a", "b"], kinds: nil)

        #expect(shingles.isEmpty)
    }

    @Test("Character shingles generation")
    func characterShingles() {
        let generator = ShingleGenerator()
        let text = "hello world"
        let shingles = generator.generateCharacterShingles(from: text, k: 3)

        // "hel", "ell", "llo", "lo ", "o w", " wo", "wor", "orl", "rld"
        #expect(shingles.count == 9)
    }

    @Test("Different shingle sizes")
    func differentShingleSizes() {
        let tokens = ["a", "b", "c", "d", "e", "f"]

        for size in 1 ... 5 {
            let generator = ShingleGenerator(shingleSize: size, normalize: false)
            let shingles = generator.generate(tokens: tokens, kinds: nil)
            #expect(shingles.count == tokens.count - size + 1)
        }
    }
}

// MARK: - MinHashSignatureTests

@Suite("MinHash Signature Tests")
struct MinHashSignatureTests {
    @Test("Identical sets have similarity 1.0")
    func identicalSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 100)
        let hashes: Set<UInt64> = [1, 2, 3, 4, 5]

        let sig1 = generator.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes, documentId: 1)

        let similarity = sig1.estimateSimilarity(with: sig2)
        #expect(abs(similarity - 1.0) < 0.01)
    }

    @Test("Disjoint sets have low similarity")
    func disjointSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 100)
        let hashes1: Set<UInt64> = [1, 2, 3, 4, 5]
        let hashes2: Set<UInt64> = [100, 200, 300, 400, 500]

        let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

        let similarity = sig1.estimateSimilarity(with: sig2)
        #expect(similarity < 0.2) // Should be very low
    }

    @Test("Partial overlap similarity estimation")
    func partialOverlapSimilarity() {
        let generator = MinHashGenerator(numHashes: 256)
        let common: Set<UInt64> = Set(1 ... 50)
        let unique1: Set<UInt64> = Set(51 ... 100)
        let unique2: Set<UInt64> = Set(101 ... 150)

        let hashes1 = common.union(unique1) // 100 elements, 50 in common
        let hashes2 = common.union(unique2) // 100 elements, 50 in common

        // Exact Jaccard = 50 / 150 = 0.333
        let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

        let estimated = sig1.estimateSimilarity(with: sig2)
        let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

        #expect(abs(estimated - exact) < 0.1) // Within 10%
    }

    @Test("Empty set signature")
    func emptySetSignature() {
        let generator = MinHashGenerator(numHashes: 64)
        let sig = generator.computeSignature(for: [], documentId: 0)

        #expect(sig.size == 64)
        #expect(sig.values.allSatisfy { $0 == UInt64.max })
    }

    @Test("Deterministic signatures with same seed")
    func deterministicSignatures() {
        let generator = MinHashGenerator(numHashes: 100, seed: 12345)
        let hashes: Set<UInt64> = [10, 20, 30, 40, 50]

        let sig1 = generator.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes, documentId: 1)

        // Same input should produce same signature values (different IDs)
        #expect(sig1.values == sig2.values)
    }

    @Test("Different seeds produce different signatures")
    func differentSeedsProduceDifferentSignatures() {
        let generator1 = MinHashGenerator(numHashes: 100, seed: 1)
        let generator2 = MinHashGenerator(numHashes: 100, seed: 2)
        let hashes: Set<UInt64> = [10, 20, 30, 40, 50]

        let sig1 = generator1.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator2.computeSignature(for: hashes, documentId: 0)

        #expect(sig1.values != sig2.values)
    }
}

// MARK: - MinHashAccuracyTests

@Suite("MinHash Accuracy Tests")
struct MinHashAccuracyTests {
    @Test("Similarity estimation accuracy at various thresholds")
    func similarityEstimationAccuracy() {
        let generator = MinHashGenerator(numHashes: 256)

        // Test at various Jaccard similarities
        for targetSim in stride(from: 0.2, through: 0.8, by: 0.3) {
            let overlapSize = 100
            let totalSize = Int(Double(overlapSize) / targetSim)
            let uniquePerSet = (totalSize - overlapSize) / 2

            let common: Set<UInt64> = Set((0 ..< overlapSize).map { UInt64($0) })
            let unique1: Set<UInt64> = Set((1000 ..< (1000 + uniquePerSet)).map { UInt64($0) })
            let unique2: Set<UInt64> = Set((2000 ..< (2000 + uniquePerSet)).map { UInt64($0) })

            let hashes1 = common.union(unique1)
            let hashes2 = common.union(unique2)

            let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
            let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

            let estimated = sig1.estimateSimilarity(with: sig2)
            let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

            #expect(abs(estimated - exact) < 0.15)
        }
    }

    @Test("Large sets similarity")
    func largeSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 128)
        let size = 10000
        let overlapRatio = 0.6

        let overlapSize = Int(Double(size) * overlapRatio)
        let common: Set<UInt64> = Set((0 ..< overlapSize).map { UInt64($0) })
        let unique1: Set<UInt64> = Set((size ..< (2 * size - overlapSize)).map { UInt64($0) })
        let unique2: Set<UInt64> = Set(((2 * size) ..< (3 * size - overlapSize)).map { UInt64($0) })

        let hashes1 = common.union(unique1)
        let hashes2 = common.union(unique2)

        let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

        let estimated = sig1.estimateSimilarity(with: sig2)
        let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

        #expect(abs(estimated - exact) < 0.1)
    }
}

// MARK: - LSHIndexTests

@Suite("LSH Index Tests")
struct LSHIndexTests {
    @Test("Optimal bands and rows calculation")
    func optimalBandsAndRows() {
        // Test that optimal parameters produce reasonable thresholds
        let (b1, r1) = LSHIndex.optimalBandsAndRows(signatureSize: 128, threshold: 0.5)
        #expect(b1 * r1 <= 128) // May not use all hashes
        #expect(b1 > 0)
        #expect(r1 > 0)

        let (b2, _) = LSHIndex.optimalBandsAndRows(signatureSize: 128, threshold: 0.8)
        // Higher threshold should have fewer bands (more rows)
        #expect(b2 <= b1)
    }

    @Test("Insert and query")
    func insertAndQuery() {
        let generator = MinHashGenerator(numHashes: 64)
        let hashes: Set<UInt64> = Set((0 ..< 100).map { UInt64($0) })
        let sig1 = generator.computeSignature(for: hashes, documentId: 1)
        let sig2 = generator.computeSignature(for: hashes, documentId: 2)

        var index = LSHIndex(signatureSize: 64, threshold: 0.5)
        index.insert(sig1)
        index.insert(sig2)

        // sig1 should find sig2 as candidate
        let candidates = index.query(sig1)
        #expect(candidates.contains(2))
    }

    @Test("Find candidate pairs")
    func findCandidatePairs() {
        let generator = MinHashGenerator(numHashes: 64)

        // Create 3 similar documents
        let common: Set<UInt64> = Set((0 ..< 50).map { UInt64($0) })
        let sig1 = generator.computeSignature(for: common.union([100, 101]), documentId: 1)
        let sig2 = generator.computeSignature(for: common.union([200, 201]), documentId: 2)
        let sig3 = generator.computeSignature(for: common.union([300, 301]), documentId: 3)

        // Create 1 dissimilar document
        let dissimilar: Set<UInt64> = Set((1000 ..< 1100).map { UInt64($0) })
        let sig4 = generator.computeSignature(for: dissimilar, documentId: 4)

        var index = LSHIndex(signatureSize: 64, threshold: 0.5)
        index.insert([sig1, sig2, sig3, sig4])

        let pairs = index.findCandidatePairs()

        // Similar documents should be candidates
        let hasPair12 = pairs.contains(DocumentPair(id1: 1, id2: 2))
        let hasPair13 = pairs.contains(DocumentPair(id1: 1, id2: 3))
        let hasPair23 = pairs.contains(DocumentPair(id1: 2, id2: 3))

        // At least some similar pairs should be found
        #expect(hasPair12 || hasPair13 || hasPair23)
    }

    @Test("Query with similarity threshold")
    func queryWithSimilarity() {
        let generator = MinHashGenerator(numHashes: 128)

        let base: Set<UInt64> = Set((0 ..< 100).map { UInt64($0) })
        let similar: Set<UInt64> = base.union(Set((100 ..< 120).map { UInt64($0) }))
        let dissimilar: Set<UInt64> = Set((1000 ..< 1100).map { UInt64($0) })

        let sigBase = generator.computeSignature(for: base, documentId: 0)
        let sigSimilar = generator.computeSignature(for: similar, documentId: 1)
        let sigDissimilar = generator.computeSignature(for: dissimilar, documentId: 2)

        var index = LSHIndex(signatureSize: 128, threshold: 0.5)
        index.insert([sigBase, sigSimilar, sigDissimilar])

        let results = index.queryWithSimilarity(sigBase, threshold: 0.5)

        // sigSimilar should be in results
        let similarResult = results.first { $0.documentId == 1 }
        #expect(similarResult != nil)
        if let result = similarResult {
            #expect(result.similarity > 0.5)
        }
    }
}

// MARK: - LSHPipelineTests

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

// MARK: - DocumentPairTests

@Suite("Document Pair Tests")
struct DocumentPairTests {
    @Test("Document pair normalization")
    func normalization() {
        let pair1 = DocumentPair(id1: 1, id2: 2)
        let pair2 = DocumentPair(id1: 2, id2: 1)

        #expect(pair1 == pair2)
        #expect(pair1.hashValue == pair2.hashValue)
    }

    @Test("Document pair equality")
    func equality() {
        let pair1 = DocumentPair(id1: 5, id2: 10)
        let pair2 = DocumentPair(id1: 5, id2: 10)
        let pair3 = DocumentPair(id1: 5, id2: 11)

        #expect(pair1 == pair2)
        #expect(pair1 != pair3)
    }
}

// MARK: - MinHashCloneDetectorTests

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
        let tokens1: [TokenInfo] = (0 ..< 20).map { i in
            TokenInfo(kind: .identifier, text: "token\(i % 5)", line: i / 5 + 1, column: 0)
        }
        let tokens2: [TokenInfo] = (0 ..< 20).map { i in
            TokenInfo(kind: .identifier, text: "token\(i % 5)", line: i / 5 + 1, column: 0)
        }

        let seq1 = TokenSequence(file: "file1.swift", tokens: tokens1, sourceLines: [""])
        let seq2 = TokenSequence(file: "file2.swift", tokens: tokens2, sourceLines: [""])

        let clones = detector.detect(in: [seq1, seq2])

        // All found clones should meet the similarity threshold
        #expect(clones.allSatisfy { $0.similarity >= 0.4 })
    }
}

// MARK: - FastSimilarityCheckerTests

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
        let tokens1 = ["func", "a", "(", ")", "{", "let", "x", "=", "1", "}",
                       "func", "b", "(", ")", "{", "let", "y", "=", "2", "}"]
        let tokens2 = ["func", "c", "(", ")", "{", "let", "z", "=", "3", "}",
                       "class", "D", "{", "var", "w", ":", "Int", "=", "4", "}"]
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

// MARK: - WeightedMinHashTests

@Suite("Weighted MinHash Tests")
struct WeightedMinHashTests {
    @Test("Weighted signature for identical counts")
    func weightedSignature() {
        let generator = WeightedMinHashGenerator(numHashes: 64)

        let counts1: [UInt64: Int] = [1: 5, 2: 3, 3: 1]
        let counts2: [UInt64: Int] = [1: 5, 2: 3, 3: 1]

        let sig1 = generator.computeSignature(for: counts1, documentId: 0)
        let sig2 = generator.computeSignature(for: counts2, documentId: 1)

        let similarity = sig1.estimateSimilarity(with: sig2)
        #expect(abs(similarity - 1.0) < 0.01)
    }

    @Test("Different weights affect similarity")
    func differentWeights() {
        let generator = WeightedMinHashGenerator(numHashes: 128)

        // Same elements but different weights
        let counts1: [UInt64: Int] = [1: 10, 2: 1]
        let counts2: [UInt64: Int] = [1: 1, 2: 10]

        let sig1 = generator.computeSignature(for: counts1, documentId: 0)
        let sig2 = generator.computeSignature(for: counts2, documentId: 1)

        let similarity = sig1.estimateSimilarity(with: sig2)
        // Should be less than 1.0 due to different weights
        #expect(similarity < 1.0)
    }
}

// MARK: - MinHashIntegrationTests

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

        for i in 0 ..< 10 {
            let tokens: [String] = if i < 3 {
                // Near-duplicates: same base with small variation
                ["common", "tokens", "here", "variant\(i)"]
            } else {
                // Unique documents
                ["unique", "document", "number", "\(i)", "extra\(i)"]
            }

            let shingles = shingleGen.generate(tokens: tokens, kinds: nil)
            documents.append(ShingledDocument(
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

// MARK: - ExactJaccardTests

@Suite("Exact Jaccard Similarity Tests")
struct ExactJaccardTests {
    @Test("Empty sets have zero similarity")
    func emptySets() {
        let empty: Set<UInt64> = []
        let sim = MinHashGenerator.exactJaccardSimilarity(empty, empty)
        #expect(sim == 0.0)
    }

    @Test("One empty set has zero similarity")
    func oneEmptySet() {
        let empty: Set<UInt64> = []
        let nonEmpty: Set<UInt64> = [1, 2, 3]
        let sim = MinHashGenerator.exactJaccardSimilarity(empty, nonEmpty)
        #expect(sim == 0.0)
    }

    @Test("Identical sets have similarity 1.0")
    func identicalSets() {
        let set1: Set<UInt64> = [1, 2, 3, 4, 5]
        let sim = MinHashGenerator.exactJaccardSimilarity(set1, set1)
        #expect(sim == 1.0)
    }

    @Test("Disjoint sets have similarity 0.0")
    func disjointSets() {
        let set1: Set<UInt64> = [1, 2, 3]
        let set2: Set<UInt64> = [4, 5, 6]
        let sim = MinHashGenerator.exactJaccardSimilarity(set1, set2)
        #expect(sim == 0.0)
    }

    @Test("Partial overlap has correct similarity")
    func partialOverlap() {
        // Set1: {1, 2, 3}, Set2: {2, 3, 4}
        // Intersection: {2, 3} = 2
        // Union: {1, 2, 3, 4} = 4
        // Jaccard = 2/4 = 0.5
        let set1: Set<UInt64> = [1, 2, 3]
        let set2: Set<UInt64> = [2, 3, 4]
        let sim = MinHashGenerator.exactJaccardSimilarity(set1, set2)
        #expect(sim == 0.5)
    }
}

// MARK: - BatchProcessingTests

@Suite("Batch Processing Tests")
struct BatchProcessingTests {
    @Test("Batch compute signatures")
    func batchComputeSignatures() {
        let generator = MinHashGenerator(numHashes: 64)
        let shingleGen = ShingleGenerator(shingleSize: 2, normalize: false)

        var documents: [ShingledDocument] = []
        for i in 0 ..< 5 {
            let tokens = ["token\(i)", "token\(i + 1)", "token\(i + 2)"]
            let shingles = shingleGen.generate(tokens: tokens, kinds: nil)
            documents.append(ShingledDocument(
                file: "file\(i).swift",
                startLine: 1, endLine: 1,
                tokenCount: tokens.count,
                shingleHashes: Set(shingles.map(\.hash)),
                shingles: shingles,
                id: i,
            ))
        }

        let signatures = generator.computeSignatures(for: documents)
        #expect(signatures.count == 5)
        for (i, sig) in signatures.enumerated() {
            #expect(sig.documentId == i)
            #expect(sig.size == 64)
        }
    }

    @Test("Pairwise similarities computation")
    func pairwiseSimilarities() {
        let generator = MinHashGenerator(numHashes: 64)

        // Create 3 similar signatures
        let common: Set<UInt64> = Set((0 ..< 50).map { UInt64($0) })
        let sig1 = generator.computeSignature(for: common.union([100]), documentId: 1)
        let sig2 = generator.computeSignature(for: common.union([200]), documentId: 2)
        let sig3 = generator.computeSignature(for: common.union([300]), documentId: 3)

        let pairs = generator.computePairwiseSimilarities([sig1, sig2, sig3], threshold: 0.5)

        // Should find pairs with high similarity
        #expect(!pairs.isEmpty) // May vary based on hash function
        for pair in pairs {
            #expect(pair.similarity >= 0.5)
        }
    }
}
