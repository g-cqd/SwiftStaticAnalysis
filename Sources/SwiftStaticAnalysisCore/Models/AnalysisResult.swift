//  AnalysisResult.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - AnalysisResult

/// Complete result of analyzing a codebase.
public struct AnalysisResult: Sendable {
    // MARK: Lifecycle

    public init(
        files: [String],
        declarations: DeclarationIndex,
        references: ReferenceIndex,
        scopes: ScopeTree,
        statistics: AnalysisStatistics,
    ) {
        self.files = files
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.statistics = statistics
    }

    // MARK: Public

    /// All files analyzed.
    public let files: [String]

    /// All declarations found.
    public let declarations: DeclarationIndex

    /// All references found.
    public let references: ReferenceIndex

    /// Scope hierarchy.
    public let scopes: ScopeTree

    /// Analysis statistics.
    public let statistics: AnalysisStatistics
}

// MARK: - AnalysisStatistics

/// Statistics about the analysis.
public struct AnalysisStatistics: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        fileCount: Int,
        totalLines: Int,
        declarationCount: Int,
        referenceCount: Int,
        declarationsByKind: [String: Int],
        analysisTime: TimeInterval,
    ) {
        self.fileCount = fileCount
        self.totalLines = totalLines
        self.declarationCount = declarationCount
        self.referenceCount = referenceCount
        self.declarationsByKind = declarationsByKind
        self.analysisTime = analysisTime
    }

    // MARK: Public

    /// Number of files analyzed.
    public let fileCount: Int

    /// Total lines of code.
    public let totalLines: Int

    /// Number of declarations found.
    public let declarationCount: Int

    /// Number of references found.
    public let referenceCount: Int

    /// Declarations by kind.
    public let declarationsByKind: [String: Int]

    /// Time taken for analysis in seconds.
    public let analysisTime: TimeInterval
}

// MARK: - FileAnalysisResult

/// Result of analyzing a single file.
public struct FileAnalysisResult: Sendable {
    // MARK: Lifecycle

    public init(
        file: String,
        declarations: [Declaration],
        references: [Reference],
        scopes: [Scope],
        lineCount: Int,
    ) {
        self.file = file
        self.declarations = declarations
        self.references = references
        self.scopes = scopes
        self.lineCount = lineCount
    }

    // MARK: Public

    /// The file path.
    public let file: String

    /// Declarations in this file.
    public let declarations: [Declaration]

    /// References in this file.
    public let references: [Reference]

    /// Scopes in this file.
    public let scopes: [Scope]

    /// Number of lines.
    public let lineCount: Int
}

// MARK: - AnalysisError

/// Errors that can occur during analysis.
public enum AnalysisError: Error, Sendable {
    case fileNotFound(String)
    case parseError(file: String, message: String)
    case invalidPath(String)
    case ioError(String)
}
