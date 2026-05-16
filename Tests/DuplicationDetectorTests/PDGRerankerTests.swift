//  PDGRerankerTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("PDG Reranker")
struct PDGRerankerTests {
    @Test("Identical snippets score 1.0")
    func identicalSnippetsScoreFull() {
        guard FileManager.default.fileExists(atPath: "/usr/bin/swiftc") else {
            // No swiftc on this runner — gracefully skip.
            return
        }
        let snippet = """
            func add(_ a: Int, _ b: Int) -> Int {
                return a + b
            }
            """
        let reranker = PDGReranker()
        let score = reranker.score(snippet, snippet)
        #expect(score >= 0.99)
    }

    @Test("Different snippets score below threshold")
    func differentSnippetsScoreLower() {
        guard FileManager.default.fileExists(atPath: "/usr/bin/swiftc") else { return }
        let a = """
            func add(_ a: Int, _ b: Int) -> Int {
                return a + b
            }
            """
        let b = """
            func printHello() {
                print("hello")
            }
            """
        let reranker = PDGReranker()
        let score = reranker.score(a, b)
        #expect(score < 0.95)
    }

    @Test("Uncompilable snippet returns 1.0 (gate falls open)")
    func uncompilableSnippetFallsOpen() {
        let badSnippet = "this is not swift at all !!!"
        let reranker = PDGReranker()
        let score = reranker.score(badSnippet, badSnippet)
        #expect(score == 1.0)
    }
}
