//  DiagnosticProducerTests.swift
//  SwiftStaticAnalysisLSPServerTests
//  MIT License

import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore
import Testing
import UnusedCodeDetector

@testable import SwiftStaticAnalysisLSPServer

@Suite("DiagnosticProducer")
struct DiagnosticProducerTests {
    // MARK: - Unused-decl mapping

    @Test("mapUnused converts 1-based SourceLocation to 0-based LSP range")
    func mapUnusedConvertsCoordinates() {
        let location = SourceLocation(file: "/tmp/Foo.swift", line: 5, column: 7)
        let range = SourceRange(start: location, end: location)
        let declaration = Declaration(
            name: "unusedSymbol",
            kind: .function,
            accessLevel: .internal,
            location: location,
            range: range,
            scope: ScopeID("test-scope")
        )
        let unused = UnusedCode(
            declaration: declaration,
            reason: .neverReferenced,
            confidence: .high,
            suggestion: "Remove this"
        )

        let diagnostic = DiagnosticProducer.mapUnused(unused)

        // 1-based -> 0-based.
        #expect(diagnostic.range.start.line == 4)
        #expect(diagnostic.range.start.character == 6)
        // End character spans the identifier length.
        #expect(diagnostic.range.end.character == 6 + "unusedSymbol".utf16.count)
        // High confidence maps to .warning.
        #expect(diagnostic.severity == .warning)
        // Source tags the diagnostic as coming from this tool.
        #expect(diagnostic.source == "swa")
        // Code reflects the underlying reason for filtering in editors.
        #expect(diagnostic.code == "unused.neverReferenced")
        // Message embeds the declaration name so the user can find it.
        #expect(diagnostic.message.contains("unusedSymbol"))
    }

    @Test("mapUnused confidence -> severity mapping")
    func mapUnusedSeverityMapping() {
        func diagnostic(for confidence: Confidence) -> LSPDiagnostic {
            let location = SourceLocation(file: "/tmp/Foo.swift", line: 1, column: 1)
            let declaration = Declaration(
                name: "x",
                kind: .variable,
                location: location,
                range: SourceRange(start: location, end: location),
                scope: ScopeID("test-scope")
            )
            return DiagnosticProducer.mapUnused(
                UnusedCode(declaration: declaration, reason: .neverReferenced, confidence: confidence)
            )
        }

        #expect(diagnostic(for: .high).severity == .warning)
        #expect(diagnostic(for: .medium).severity == .information)
        #expect(diagnostic(for: .low).severity == .hint)
    }

    // MARK: - Duplicate-block mapping

    @Test("mapClone converts 1-based start/end lines to 0-based LSP range spanning the block")
    func mapCloneConvertsBlockRange() {
        let clone = Clone(
            file: "/tmp/Foo.swift",
            startLine: 10,
            endLine: 14,
            tokenCount: 80,
            codeSnippet: "..."
        )
        let group = CloneGroup(
            type: .exact,
            clones: [clone, clone],
            similarity: 1.0,
            fingerprint: "abc"
        )

        let diagnostic = DiagnosticProducer.mapClone(clone, group: group)

        // Start at zero-based start line, character 0.
        #expect(diagnostic.range.start == LSPPosition(line: 9, character: 0))
        // End at the start of the line *after* the last clone line so
        // the highlight covers the whole block — endLine (14) - 1 = 13,
        // then +1 for the next-line anchor = 14.
        #expect(diagnostic.range.end == LSPPosition(line: 14, character: 0))
        #expect(diagnostic.severity == .information)
        #expect(diagnostic.source == "swa")
        #expect(diagnostic.code == "duplicate.exact")
        #expect(diagnostic.message.contains("Duplicate"))
        #expect(diagnostic.message.contains("2 occurrences"))
    }

    // MARK: - URI <-> path round-trip

    @Test("URIPathConverter round-trips file paths through file:// URIs")
    func uriPathConverterRoundTrip() {
        let path = "/Users/example/Sources/Foo.swift"
        let uri = URIPathConverter.uri(fromPath: path)
        #expect(uri.hasPrefix("file://"))
        #expect(URIPathConverter.path(fromURI: uri) == path)
    }

    @Test("URIPathConverter returns nil for non-file URIs")
    func uriPathConverterRejectsNonFileURIs() {
        #expect(URIPathConverter.path(fromURI: "https://example.com/foo") == nil)
    }
}
