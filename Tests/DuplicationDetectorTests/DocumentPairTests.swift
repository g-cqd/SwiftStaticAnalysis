//  DocumentPairTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

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
