//  FunctionSnippetExtractor.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - FunctionSnippetExtractor

/// Extracts function- and initializer-shaped `EmbeddingSnippet`s from
/// Swift source. Used as the input feeder for
/// `EmbeddingCloneDiscovery` when scanning a real codebase from the
/// `swa duplicates --embedding-bundle <dir>` CLI surface.
///
/// Skips snippets shorter than `minimumLines` (5) and longer than
/// `maximumLines` (60) — same window the SOTA-comparison script uses,
/// keeping the input distribution comparable to the Python harness.
///
/// Trivia (leading comments, whitespace) is preserved verbatim so the
/// tokenizer sees the same context a human reviewer would.
public enum FunctionSnippetExtractor {
    public static let minimumLines = 5
    public static let maximumLines = 60

    /// Walk a single source string and emit one `EmbeddingSnippet` per
    /// function / initializer body that fits inside the line window.
    public static func extract(
        source: String,
        file: String,
        minimumLines: Int = minimumLines,
        maximumLines: Int = maximumLines,
    ) -> [EmbeddingSnippet] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: file, tree: tree)
        let visitor = SnippetVisitor(
            converter: converter,
            source: source,
            file: file,
            minimumLines: minimumLines,
            maximumLines: maximumLines,
        )
        visitor.walk(tree)
        return visitor.snippets
    }

    /// Convenience: walk a file URL and parse its contents.
    public static func extract(
        fileURL: URL,
        minimumLines: Int = minimumLines,
        maximumLines: Int = maximumLines,
    ) throws -> [EmbeddingSnippet] {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        return extract(
            source: source,
            file: fileURL.path,
            minimumLines: minimumLines,
            maximumLines: maximumLines,
        )
    }

    /// Walk a directory tree, parse every `.swift` file, and return the
    /// combined `[EmbeddingSnippet]`. Skips hidden directories and the
    /// `.build` / `Models` SPM artifact dirs.
    public static func extract(
        directory: URL,
        minimumLines: Int = minimumLines,
        maximumLines: Int = maximumLines,
    ) throws -> [EmbeddingSnippet] {
        var out: [EmbeddingSnippet] = []
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
            )
        else { return [] }
        for case let url as URL in enumerator {
            let path = url.path
            if path.contains("/.build/") || path.contains("/Models/") {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            let snippets = try extract(
                fileURL: url,
                minimumLines: minimumLines,
                maximumLines: maximumLines,
            )
            out.append(contentsOf: snippets)
        }
        return out
    }
}

// MARK: - SnippetVisitor

private final class SnippetVisitor: SyntaxVisitor {
    init(
        converter: SourceLocationConverter,
        source: String,
        file: String,
        minimumLines: Int,
        maximumLines: Int,
    ) {
        self.converter = converter
        self.source = source
        self.file = file
        self.minimumLines = minimumLines
        self.maximumLines = maximumLines
        super.init(viewMode: .sourceAccurate)
    }

    var snippets: [EmbeddingSnippet] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node: Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        consider(node: Syntax(node))
        return .visitChildren
    }

    private func consider(node: Syntax) {
        let start = node.startLocation(converter: converter)
        let end = node.endLocation(converter: converter)
        let startLine = start.line
        let endLine = end.line
        let lineSpan = endLine - startLine + 1
        guard lineSpan >= minimumLines, lineSpan <= maximumLines else { return }
        let code = node.description
        // Cheap token estimate — actual model tokenization happens in the
        // provider; this is just for the `EmbeddingSnippet` field.
        let approxTokenCount = max(1, code.count / 4)
        snippets.append(
            EmbeddingSnippet(
                file: file,
                startLine: startLine,
                endLine: endLine,
                tokenCount: approxTokenCount,
                code: code,
            )
        )
    }

    private let converter: SourceLocationConverter
    private let source: String
    private let file: String
    private let minimumLines: Int
    private let maximumLines: Int
}
