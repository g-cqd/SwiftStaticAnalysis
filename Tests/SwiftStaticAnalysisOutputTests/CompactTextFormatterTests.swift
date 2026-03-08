//  CompactTextFormatterTests.swift
//  SwiftStaticAnalysis
//  MIT License

import DuplicationDetector
import SwiftStaticAnalysisCore
import Testing
import UnusedCodeDetector

@testable import SwiftStaticAnalysisOutput

@Suite("CompactTextFormatter Tests")
struct CompactTextFormatterTests {
    @Test("formatUnused includes header and shortens paths")
    func formatUnusedIncludesHeaderAndShortensPaths() {
        let rootPath = "/tmp/project"
        let item = makeUnusedCode(
            file: "\(rootPath)/Sources/App/Feature.swift",
            line: 42,
            name: "unusedHelper"
        )

        let output = CompactTextFormatter.formatUnused([item], rootPath: rootPath)

        #expect(output.contains("UNUSED 1 items"))
        #expect(output.contains("Sources/App/Feature.swift"))
        #expect(!output.contains(rootPath))
        #expect(output.contains("42 function unusedHelper [H] unused"))
    }

    @Test("formatClones can omit header for CLI output")
    func formatClonesOmitsHeaderForCLIOutput() {
        let group = CloneGroup(
            type: .exact,
            clones: [
                Clone(file: "/tmp/project/A.swift", startLine: 10, endLine: 14, tokenCount: 20, codeSnippet: "a"),
                Clone(file: "/tmp/project/B.swift", startLine: 20, endLine: 24, tokenCount: 20, codeSnippet: "b"),
            ],
            similarity: 1.0,
            fingerprint: "A|B"
        )

        let output = CompactTextFormatter.formatClones([group], includeHeader: false)

        #expect(output.hasPrefix("\nexact 1 groups 10 duplicated lines"))
        #expect(!output.contains("CLONES 1 groups"))
        #expect(output.contains("/tmp/project/A.swift: 10-14"))
        #expect(output.contains("/tmp/project/B.swift: 20-24"))
    }

    private func makeUnusedCode(file: String, line: Int, name: String) -> UnusedCode {
        let location = SourceLocation(file: file, line: line, column: 1, offset: 0)
        let declaration = Declaration(
            name: name,
            kind: .function,
            location: location,
            range: SourceRange(start: location, end: location),
            scope: .global
        )

        return UnusedCode(
            declaration: declaration,
            reason: .neverReferenced,
            confidence: .high
        )
    }
}
