//  DiagnosticProducer.swift
//  SwiftStaticAnalysis
//  MIT License

import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore
import UnusedCodeDetector

// MARK: - DiagnosticProducer

/// Runs the SwiftStaticAnalysis pipelines (`DuplicationDetector`,
/// `UnusedCodeDetector`) against an in-memory document snapshot and
/// maps their results into LSP `Diagnostic` arrays.
///
/// ## Design
///
/// The producer is a value type with no shared mutable state — every
/// call to `diagnose(uri:text:)` is independent. The expensive work
/// happens inside `UnusedCodeDetector.detectFromSource` and
/// `DuplicationDetector.detectClones`, which the producer composes
/// behind a single async entry point.
///
/// Because LSP clients send entire document snapshots over the wire,
/// we treat each analysis as a "single-file context" — duplicate
/// detection runs against the open document's text only, written to
/// a temporary file. This matches the "diagnostics for the document
/// in the editor" semantics of the LSP `textDocument/diagnostic`
/// flow; cross-file clone detection is out of scope.
public struct DiagnosticProducer: Sendable {
    // MARK: Lifecycle

    public init(
        unusedConfiguration: UnusedCodeConfiguration = .default,
        duplicationConfiguration: DuplicationConfiguration = .default
    ) {
        self.unusedConfiguration = unusedConfiguration
        self.duplicationConfiguration = duplicationConfiguration
    }

    // MARK: Public

    public let unusedConfiguration: UnusedCodeConfiguration
    public let duplicationConfiguration: DuplicationConfiguration

    /// Produce LSP diagnostics for a single open document.
    ///
    /// - Parameters:
    ///   - uri: `file://` URI for the document being analyzed.
    ///   - text: Current document contents (as captured by didOpen /
    ///     didChange notifications).
    /// - Returns: Diagnostics suitable for `publishDiagnostics`. Empty
    ///   if no findings or if the URI is not a `file://` URI.
    public func diagnose(uri: String, text: String) async -> [LSPDiagnostic] {
        guard let filePath = URIPathConverter.path(fromURI: uri) else {
            return []
        }

        async let unusedDiagnostics = produceUnusedDiagnostics(filePath: filePath, text: text)
        async let duplicateDiagnostics = produceDuplicateDiagnostics(filePath: filePath, text: text)

        let unused = await unusedDiagnostics
        let duplicates = await duplicateDiagnostics

        return unused + duplicates
    }

    // MARK: Internal

    /// Map a single `UnusedCode` finding into an LSP diagnostic.
    /// `internal` for unit-test access.
    static func mapUnused(_ unused: UnusedCode) -> LSPDiagnostic {
        let location = unused.declaration.location
        let nameLength = unused.declaration.name.utf16.count
        // SourceLocation is 1-based, LSP is 0-based.
        let line = max(0, location.line - 1)
        let column = max(0, location.column - 1)
        let range = LSPRange(
            start: LSPPosition(line: line, character: column),
            end: LSPPosition(line: line, character: column + max(nameLength, 1))
        )
        let severity = mapConfidence(unused.confidence)
        let message =
            "[\(unused.confidence.rawValue)] \(humanReason(unused.reason)): "
            + "'\(unused.declaration.name)' — \(unused.suggestion)"
        return LSPDiagnostic(
            range: range,
            severity: severity,
            code: "unused.\(unused.reason.rawValue)",
            source: "swa",
            message: message
        )
    }

    /// Map a single `Clone` occurrence into an LSP diagnostic.
    /// `internal` for unit-test access.
    static func mapClone(_ clone: Clone, group: CloneGroup) -> LSPDiagnostic {
        // Clone line numbers are 1-based.
        let startLine = max(0, clone.startLine - 1)
        let endLine = max(startLine, clone.endLine - 1)
        let range = LSPRange(
            start: LSPPosition(line: startLine, character: 0),
            // End at the start of the line after the clone so editors
            // highlight the entire block.
            end: LSPPosition(line: endLine + 1, character: 0)
        )
        let message =
            "[\(group.type.rawValue)] Duplicate code block — \(group.occurrences) occurrences "
            + "(\(clone.tokenCount) tokens, similarity \(String(format: "%.2f", group.similarity)))"
        return LSPDiagnostic(
            range: range,
            severity: .information,
            code: "duplicate.\(group.type.rawValue)",
            source: "swa",
            message: message
        )
    }

    // MARK: Private

    /// Map detection confidence to LSP severity. Higher confidence ->
    /// stronger signal in the editor.
    private static func mapConfidence(_ confidence: Confidence) -> LSPDiagnosticSeverity {
        switch confidence {
        case .high: .warning
        case .medium: .information
        case .low: .hint
        }
    }

    private static func humanReason(_ reason: UnusedReason) -> String {
        switch reason {
        case .neverReferenced: "Unused declaration"
        case .onlyAssigned: "Variable assigned but never read"
        case .onlySelfReferenced: "Only self-referenced"
        case .importNotUsed: "Unused import"
        case .parameterUnused: "Unused parameter"
        }
    }

    private func produceUnusedDiagnostics(filePath: String, text: String) async -> [LSPDiagnostic] {
        let detector = UnusedCodeDetector(configuration: unusedConfiguration)
        do {
            let findings = try await detector.detectFromSource(text, file: filePath)
            return findings.map(Self.mapUnused)
        } catch {
            return []
        }
    }

    /// Duplicate detection works on file paths, so we write the open
    /// document to a sandboxed temporary file before invoking it. The
    /// temp file is removed on the way out. Errors are swallowed —
    /// editor diagnostics should fail open.
    private func produceDuplicateDiagnostics(filePath: String, text: String) async -> [LSPDiagnostic] {
        let detector = DuplicationDetector(configuration: duplicationConfiguration)
        let scratchURL = scratchFile(forOpenPath: filePath)
        do {
            try text.write(to: scratchURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: scratchURL) }

            let groups = try await detector.detectClones(in: [scratchURL.path])
            var diagnostics: [LSPDiagnostic] = []
            for group in groups {
                for clone in group.clones where clone.file == scratchURL.path {
                    diagnostics.append(Self.mapClone(clone, group: group))
                }
            }
            return diagnostics
        } catch {
            try? FileManager.default.removeItem(at: scratchURL)
            return []
        }
    }

    /// Allocate a unique temporary file in `NSTemporaryDirectory()`
    /// derived from the open document's filename so the analyzer logs
    /// remain attributable to the original document.
    private func scratchFile(forOpenPath path: String) -> URL {
        let basename = (path as NSString).lastPathComponent
        let tempDir = NSTemporaryDirectory()
        let unique = "swa-lsp-\(UUID().uuidString)-\(basename)"
        return URL(fileURLWithPath: tempDir).appendingPathComponent(unique)
    }
}
