//
//  SwiftStaticAnalysisCore.swift
//  SwiftStaticAnalysis
//
//  Core infrastructure for Swift static analysis.
//

import Foundation
@_exported import SwiftParser
// Re-export SwiftSyntax types commonly needed by consumers
@_exported import SwiftSyntax

// MARK: - Module Exports

// Models
public typealias SourceLocationConverter = SwiftSyntax.SourceLocationConverter

// MARK: - StaticAnalyzer

/// Main entry point for analyzing Swift source files.
public struct StaticAnalyzer: Sendable {
    // MARK: Lifecycle

    public init(
        configuration: AnalyzerConfiguration = .default,
        concurrency: ConcurrencyConfiguration = .default,
    ) {
        parser = SwiftFileParser()
        self.configuration = configuration
        self.concurrency = concurrency
    }

    // MARK: Public

    /// The file parser.
    public let parser: SwiftFileParser

    /// Configuration for the analyzer.
    public let configuration: AnalyzerConfiguration

    /// Concurrency configuration.
    public let concurrency: ConcurrencyConfiguration

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
            lineCount: lineCount,
        )
    }

    /// Analyze Swift source code from a string.
    ///
    /// - Parameters:
    ///   - source: Swift source code string.
    ///   - file: Virtual file name for reporting.
    /// - Returns: Analysis result for the source.
    public func analyzeSource(_ source: String, file: String) async throws -> AnalysisResult {
        let syntax = try await parser.parse(source: source)
        let lineCount = try await parser.lineCount(source: source)

        // Collect declarations
        let declCollector = DeclarationCollector(file: file, tree: syntax)
        declCollector.walk(syntax)

        // Collect references
        let refCollector = ReferenceCollector(file: file, tree: syntax)
        refCollector.walk(syntax)

        var declarationIndex = DeclarationIndex()
        var referenceIndex = ReferenceIndex()
        var scopeTree = ScopeTree()
        var declarationsByKind: [String: Int] = [:]

        for decl in declCollector.declarations + declCollector.imports {
            declarationIndex.add(decl)
            declarationsByKind[decl.kind.rawValue, default: 0] += 1
        }

        for ref in refCollector.references {
            referenceIndex.add(ref)
        }

        for scope in declCollector.tracker.tree.scopes.values {
            scopeTree.add(scope)
        }

        let statistics = AnalysisStatistics(
            fileCount: 1,
            totalLines: lineCount,
            declarationCount: declarationIndex.declarations.count,
            referenceCount: referenceIndex.references.count,
            declarationsByKind: declarationsByKind,
            analysisTime: 0,
        )

        return AnalysisResult(
            files: [file],
            declarations: declarationIndex,
            references: referenceIndex,
            scopes: scopeTree,
            statistics: statistics,
        )
    }

    /// Analyze multiple Swift files.
    ///
    /// - Parameter filePaths: Array of file paths.
    /// - Returns: Combined analysis result.
    public func analyze(_ filePaths: [String]) async throws -> AnalysisResult {
        let startTime = Date()

        // Analyze files in parallel with concurrency limits
        let results = try await ParallelProcessor.map(
            filePaths,
            maxConcurrency: concurrency.maxConcurrentFiles,
        ) { path in
            try await analyzeFile(path)
        }

        // Aggregate results (sequential - fast operation)
        var declarationIndex = DeclarationIndex()
        var referenceIndex = ReferenceIndex()
        var scopeTree = ScopeTree()
        var totalLines = 0
        var declarationsByKind: [String: Int] = [:]

        for result in results {
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

        let statistics = AnalysisStatistics(
            fileCount: filePaths.count,
            totalLines: totalLines,
            declarationCount: declarationIndex.declarations.count,
            referenceCount: referenceIndex.references.count,
            declarationsByKind: declarationsByKind,
            analysisTime: Date().timeIntervalSince(startTime),
        )

        return AnalysisResult(
            files: filePaths,
            declarations: declarationIndex,
            references: referenceIndex,
            scopes: scopeTree,
            statistics: statistics,
        )
    }
}

// MARK: - AnalyzerConfiguration

/// Configuration for the static analyzer.
public struct AnalyzerConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        includePrivate: Bool = true,
        includeImports: Bool = true,
        extractDocumentation: Bool = true,
    ) {
        self.includePrivate = includePrivate
        self.includeImports = includeImports
        self.extractDocumentation = extractDocumentation
    }

    // MARK: Public

    /// Default configuration.
    public static let `default` = Self()

    /// Whether to include private declarations.
    public var includePrivate: Bool

    /// Whether to include imports.
    public var includeImports: Bool

    /// Whether to extract documentation comments.
    public var extractDocumentation: Bool
}
