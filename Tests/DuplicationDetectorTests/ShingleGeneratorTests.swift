//  ShingleGeneratorTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("Shingle Generator Tests")
struct ShingleGeneratorTests {
    @Test("Basic shingle generation")
    func basicShingleGeneration() {
        let generator = ShingleGenerator(shingleSize: 3, normalize: false)
        let tokens = ["a", "b", "c", "d", "e"]
        let shingles = generator.generate(tokens: tokens, kinds: nil)

        #expect(shingles.count == 3)  // 5 tokens - 3 + 1 = 3 shingles
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

        for size in 1...5 {
            let generator = ShingleGenerator(shingleSize: size, normalize: false)
            let shingles = generator.generate(tokens: tokens, kinds: nil)
            #expect(shingles.count == tokens.count - size + 1)
        }
    }
}
