//
//  ConcurrentParsingTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify concurrent parsing works correctly
//
//  ## Coverage
//  - Parsing multiple sources concurrently with TaskGroup
//

import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import SwiftStaticAnalysisCore

@Suite("Concurrent Parsing Tests")
struct ConcurrentParsingTests {
    @Test("Parse multiple sources concurrently")
    func parseConcurrently() async throws {
        let sources = (1...10).map { i in
            """
            struct Type\(i) {
                let value: Int = \(i)
            }
            """
        }

        let parser = SwiftFileParser()

        try await withThrowingTaskGroup(of: SourceFileSyntax.self) { group in
            for source in sources {
                group.addTask {
                    try await parser.parse(source: source)
                }
            }

            var results: [SourceFileSyntax] = []
            for try await tree in group {
                results.append(tree)
            }

            #expect(results.count == 10)
        }
    }
}
