//
//  SwiftStaticAnalysisCore.swift
//  SwiftStaticAnalysis
//
//  Core infrastructure for Swift static analysis.
//

import Foundation

// Re-export SwiftSyntax types commonly needed by consumers
@_exported import SwiftSyntax
@_exported import SwiftParser

// MARK: - Module Exports

// Models
public typealias SourceLocationConverter = SwiftSyntax.SourceLocationConverter

// MARK: - Static Analyzer

/// Main entry point for analyzing Swift source files.
public struct StaticAnalyzer: Sendable {
    /// The file parser.
    public let parser: SwiftFileParser

    /// Configuration for the analyzer.
    public let configuration: AnalyzerConfiguration

    public init(configuration: AnalyzerConfiguration = .default) {
        self.parser = SwiftFileParser()
        self.configuration = configuration
    }

    /// Analyze a single Swift file.
    ///
    /// - Parameter filePath: Path to the Swift file.
    /// - Returns: Analysis result for the file.
    public func analyzeFile(_ filePath: String) async throws -> FileAnalysisResult {
        let syntax = try await parser.parse(filePath)
        let lineCount = await parser.lineCount(for: filePath) ?? 0

        // Collect declarations
        let declCollector = DeclarationCollector(file: filePath, tree: syntax)
        declCollector.walk(syntax)

        // Collect references
        let refCollector = ReferenceCollector(file: filePath, tree: syntax)
        refCollector.walk(syntax)

        return FileAnalysisResult(
            file: filePath,
            declarations: declCollector.declarations + declCollector.imports,
            references: refCollector.references,
            scopes: Array(declCollector.tracker.tree.scopes.values),
            lineCount: lineCount
        )
    }

    /// Analyze multiple Swift files.
    ///
    /// - Parameter filePaths: Array of file paths.
    /// - Returns: Combined analysis result.
    public func analyze(_ filePaths: [String]) async throws -> AnalysisResult {
        let startTime = Date()

        var declarationIndex = DeclarationIndex()
        var referenceIndex = ReferenceIndex()
        var scopeTree = ScopeTree()
        var totalLines = 0
        var declarationsByKind: [String: Int] = [:]

        // Analyze files concurrently
        try await withThrowingTaskGroup(of: FileAnalysisResult.self) { group in
            for path in filePaths {
                group.addTask {
                    try await self.analyzeFile(path)
                }
            }

            for try await result in group {
                totalLines += result.lineCount

                for decl in result.declarations {
                    declarationIndex.add(decl)
                    declarationsByKind[decl.kind.rawValue, default: 0] += 1
                }

                for ref in result.references {
                    referenceIndex.add(ref)
                }

                for scope in result.scopes {
                    scopeTree.add(scope)
                }
            }
        }

        let statistics = AnalysisStatistics(
            fileCount: filePaths.count,
            totalLines: totalLines,
            declarationCount: declarationIndex.declarations.count,
            referenceCount: referenceIndex.references.count,
            declarationsByKind: declarationsByKind,
            analysisTime: Date().timeIntervalSince(startTime)
        )

        return AnalysisResult(
            files: filePaths,
            declarations: declarationIndex,
            references: referenceIndex,
            scopes: scopeTree,
            statistics: statistics
        )
    }
}

// MARK: - Analyzer Configuration

/// Configuration for the static analyzer.
public struct AnalyzerConfiguration: Sendable {
    /// Whether to include private declarations.
    public var includePrivate: Bool

    /// Whether to include imports.
    public var includeImports: Bool

    /// Whether to extract documentation comments.
    public var extractDocumentation: Bool

    public init(
        includePrivate: Bool = true,
        includeImports: Bool = true,
        extractDocumentation: Bool = true
    ) {
        self.includePrivate = includePrivate
        self.includeImports = includeImports
        self.extractDocumentation = extractDocumentation
    }

    /// Default configuration.
    public static let `default` = AnalyzerConfiguration()
}
