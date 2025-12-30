//
//  DiagnosticTests.swift
//  SwiftStaticAnalysis
//
//  Tests for diagnostics and Xcode formatting.
//

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

// MARK: - DiagnosticModelTests

@Suite("Diagnostic Model Tests")
struct DiagnosticModelTests {
    @Test("Diagnostic Xcode format")
    func diagnosticXcodeFormat() {
        let diagnostic = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .warning,
            message: "Unused variable 'foo'",
        )

        let expected = "/path/to/file.swift:42:5: warning: Unused variable 'foo'"
        #expect(diagnostic.xcodeFormat == expected)
    }

    @Test("Diagnostic with notes")
    func diagnosticWithNotes() {
        let note = Diagnostic(
            file: "/path/to/file.swift",
            line: 50,
            column: 1,
            severity: .note,
            message: "Related declaration here",
        )

        let diagnostic = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .warning,
            message: "Duplicate code detected",
            notes: [note],
        )

        let formatted = diagnostic.xcodeFormatWithNotes
        #expect(formatted.contains("warning: Duplicate code detected"))
        #expect(formatted.contains("note: Related declaration here"))
    }

    @Test("Diagnostic unique key")
    func diagnosticUniqueKey() {
        let d1 = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .warning,
            message: "Message",
        )

        let d2 = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .warning,
            message: "Message",
        )

        let d3 = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .error,
            message: "Message",
        )

        #expect(d1.uniqueKey == d2.uniqueKey)
        #expect(d1.uniqueKey != d3.uniqueKey)
    }

    @Test("Diagnostic severity levels")
    func diagnosticSeverityLevels() {
        #expect(DiagnosticSeverity.error.xcodeString == "error")
        #expect(DiagnosticSeverity.warning.xcodeString == "warning")
        #expect(DiagnosticSeverity.note.xcodeString == "note")
        #expect(DiagnosticSeverity.remark.xcodeString == "remark")
    }

    @Test("Diagnostic builder")
    func diagnosticBuilder() {
        let diagnostic = DiagnosticBuilder()
            .file("/path/to/file.swift")
            .location(line: 10, column: 3)
            .severity(.warning)
            .message("Test message")
            .category(.unusedCode)
            .ruleID("unused-variable")
            .build()

        #expect(diagnostic.file == "/path/to/file.swift")
        #expect(diagnostic.line == 10)
        #expect(diagnostic.column == 3)
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.message == "Test message")
        #expect(diagnostic.category == .unusedCode)
        #expect(diagnostic.ruleID == "unused-variable")
    }
}

// MARK: - DiagnosticDeduplicationTests

@Suite("Diagnostic Deduplication Tests")
struct DiagnosticDeduplicationTests {
    @Test("Deduplicate exact duplicates")
    func deduplicateExactDuplicates() {
        let diagnostics = [
            Diagnostic(file: "a.swift", line: 1, column: 1, severity: .warning, message: "Test"),
            Diagnostic(file: "a.swift", line: 1, column: 1, severity: .warning, message: "Test"),
            Diagnostic(file: "a.swift", line: 2, column: 1, severity: .warning, message: "Test"),
        ]

        let deduplicator = DiagnosticDeduplicator()
        let result = deduplicator.deduplicate(diagnostics)

        #expect(result.count == 2)
    }

    @Test("Deduplicate by location only")
    func deduplicateByLocation() {
        let diagnostics = [
            Diagnostic(file: "a.swift", line: 1, column: 1, severity: .warning, message: "Message 1"),
            Diagnostic(file: "a.swift", line: 1, column: 1, severity: .error, message: "Message 2"),
        ]

        let config = DeduplicationConfiguration(deduplicationLevel: .location)
        let deduplicator = DiagnosticDeduplicator(configuration: config)
        let result = deduplicator.deduplicate(diagnostics)

        #expect(result.count == 1)
    }

    @Test("Merge diagnostics from multiple sources")
    func mergeDiagnosticsFromMultipleSources() {
        let source1 = [
            Diagnostic(file: "a.swift", line: 1, column: 1, severity: .warning, message: "From source 1")
        ]

        let source2 = [
            Diagnostic(file: "a.swift", line: 2, column: 1, severity: .warning, message: "From source 2"),
            Diagnostic(file: "b.swift", line: 1, column: 1, severity: .warning, message: "From source 2"),
        ]

        let deduplicator = DiagnosticDeduplicator()
        let result = deduplicator.merge([source1, source2])

        #expect(result.count == 3)
        // Should be sorted by file, then line
        #expect(result[0].file == "a.swift")
        #expect(result[0].line == 1)
        #expect(result[1].file == "a.swift")
        #expect(result[1].line == 2)
        #expect(result[2].file == "b.swift")
    }

    @Test("Apply per-file limit")
    func applyPerFileLimit() {
        var diagnostics: [Diagnostic] = []
        for i in 1...10 {
            diagnostics.append(
                Diagnostic(
                    file: "a.swift",
                    line: i,
                    column: 1,
                    severity: .warning,
                    message: "Warning \(i)",
                ))
        }

        let config = DeduplicationConfiguration(maxDiagnosticsPerFile: 5)
        let deduplicator = DiagnosticDeduplicator(configuration: config)
        let result = deduplicator.deduplicate(diagnostics)

        // Should have 5 warnings + 1 summary note
        #expect(result.count == 6)
        #expect(result.last?.severity == .note)
        #expect(result.last?.message.contains("suppressed") == true)
    }

    @Test("Merge removes duplicates across sources")
    func mergeRemovesDuplicatesAcrossSources() {
        let source1 = [
            Diagnostic(file: "a.swift", line: 1, column: 1, severity: .warning, message: "Same warning")
        ]

        let source2 = [
            Diagnostic(file: "a.swift", line: 1, column: 1, severity: .warning, message: "Same warning")
        ]

        let deduplicator = DiagnosticDeduplicator()
        let result = deduplicator.merge([source1, source2])

        #expect(result.count == 1)
    }
}

// MARK: - XcodeFormatterTests

@Suite("Xcode Formatter Tests")
struct XcodeFormatterTests {
    @Test("Format single diagnostic")
    func formatSingleDiagnostic() {
        let diagnostic = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .warning,
            message: "Unused variable 'foo'",
        )

        let formatter = XcodeFormatter()
        let result = formatter.format([diagnostic])

        #expect(result == "/path/to/file.swift:42:5: warning: Unused variable 'foo'")
    }

    @Test("Format with rule ID")
    func formatWithRuleID() {
        let diagnostic = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .warning,
            message: "Unused variable",
            ruleID: "unused-var",
        )

        let config = XcodeFormatterConfiguration(includeRuleID: true)
        let formatter = XcodeFormatter(configuration: config)
        let result = formatter.format([diagnostic])

        #expect(result.contains("[unused-var]"))
    }

    @Test("Format with category")
    func formatWithCategory() {
        let diagnostic = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .warning,
            message: "Duplicate code",
            category: .duplication,
        )

        let config = XcodeFormatterConfiguration(includeCategory: true)
        let formatter = XcodeFormatter(configuration: config)
        let result = formatter.format([diagnostic])

        #expect(result.contains("(duplication)"))
    }

    @Test("Format multiple diagnostics")
    func formatMultipleDiagnostics() {
        let diagnostics = [
            Diagnostic(file: "a.swift", line: 1, column: 1, severity: .warning, message: "Warning 1"),
            Diagnostic(file: "a.swift", line: 2, column: 1, severity: .error, message: "Error 1"),
            Diagnostic(file: "b.swift", line: 1, column: 1, severity: .note, message: "Note 1"),
        ]

        let formatter = XcodeFormatter()
        let result = formatter.format(diagnostics)
        let lines = result.split(separator: "\n")

        #expect(lines.count == 3)
        #expect(lines[0].contains("warning:"))
        #expect(lines[1].contains("error:"))
        #expect(lines[2].contains("note:"))
    }

    @Test("Format diagnostic with notes")
    func formatDiagnosticWithNotes() {
        let note = Diagnostic(
            file: "/path/to/file.swift",
            line: 50,
            column: 1,
            severity: .note,
            message: "Also appears here",
        )

        let diagnostic = Diagnostic(
            file: "/path/to/file.swift",
            line: 42,
            column: 5,
            severity: .warning,
            message: "Duplicate code",
            notes: [note],
        )

        let formatter = XcodeFormatter()
        let result = formatter.format([diagnostic])
        let lines = result.split(separator: "\n")

        #expect(lines.count == 2)
        #expect(lines[0].contains("warning: Duplicate code"))
        #expect(lines[1].contains("note: Also appears here"))
    }
}

// MARK: - DiagnosticConversionTests

@Suite("Diagnostic Conversion Tests")
struct DiagnosticConversionTests {
    @Test("Create diagnostic from unused code")
    func createDiagnosticFromUnusedCode() {
        let declaration = Declaration(
            name: "unusedVar",
            kind: .variable,
            location: SourceLocation(file: "test.swift", line: 10, column: 5, offset: 100),
            range: SourceRange(
                start: SourceLocation(file: "test.swift", line: 10, column: 5, offset: 100),
                end: SourceLocation(file: "test.swift", line: 10, column: 20, offset: 115),
            ),
            scope: .global,
        )

        let diagnostic = Diagnostic.fromUnusedCode(
            declaration: declaration,
            reason: "neverReferenced",
            suggestion: "Consider removing unused variable 'unusedVar'",
        )

        #expect(diagnostic.file == "test.swift")
        #expect(diagnostic.line == 10)
        #expect(diagnostic.column == 5)
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.category == .unusedCode)
        #expect(diagnostic.ruleID == "unused-variable")
    }

    @Test("Create diagnostics from clone group")
    func createDiagnosticsFromCloneGroup() {
        let clones: [(file: String, startLine: Int, endLine: Int)] = [
            (file: "a.swift", startLine: 10, endLine: 20),
            (file: "b.swift", startLine: 30, endLine: 40),
            (file: "c.swift", startLine: 50, endLine: 60),
        ]

        let diagnostics = Diagnostic.fromCloneGroup(
            clones: clones,
            cloneType: "exact",
        )

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].file == "a.swift")
        #expect(diagnostics[0].line == 10)
        #expect(diagnostics[0].message.contains("3 occurrences"))
        #expect(diagnostics[0].notes.count == 2)
        #expect(diagnostics[0].notes[0].file == "b.swift")
        #expect(diagnostics[0].notes[1].file == "c.swift")
    }
}
