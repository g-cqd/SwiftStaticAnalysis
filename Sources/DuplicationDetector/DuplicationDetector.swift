//
//  DuplicationDetector.swift
//  SwiftStaticAnalysis
//
//  Code duplication detection module.
//

import Foundation
import SwiftStaticAnalysisCore

// MARK: - Clone Type

/// Types of code clones.
public enum CloneType: String, Sendable, Codable, CaseIterable {
    /// Exact clones - identical code except whitespace/comments.
    case exact

    /// Near clones - similar code with renamed identifiers.
    case near

    /// Semantic clones - functionally equivalent but structurally different.
    case semantic
}

// MARK: - Clone

/// Represents a detected code clone.
public struct Clone: Sendable, Codable {
    /// File containing the clone.
    public let file: String

    /// Starting line number.
    public let startLine: Int

    /// Ending line number.
    public let endLine: Int

    /// Number of tokens in the clone.
    public let tokenCount: Int

    /// The actual code snippet.
    public let codeSnippet: String

    public init(
        file: String,
        startLine: Int,
        endLine: Int,
        tokenCount: Int,
        codeSnippet: String
    ) {
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.tokenCount = tokenCount
        self.codeSnippet = codeSnippet
    }
}

// MARK: - Clone Group

/// A group of related clones.
public struct CloneGroup: Sendable, Codable {
    /// Type of clone.
    public let type: CloneType

    /// Clones in this group.
    public let clones: [Clone]

    /// Similarity score (1.0 for exact, lower for near/semantic).
    public let similarity: Double

    /// Hash or fingerprint identifying this clone group.
    public let fingerprint: String

    public init(
        type: CloneType,
        clones: [Clone],
        similarity: Double,
        fingerprint: String
    ) {
        self.type = type
        self.clones = clones
        self.similarity = similarity
        self.fingerprint = fingerprint
    }

    /// Number of occurrences.
    public var occurrences: Int { clones.count }

    /// Total duplicated lines.
    public var duplicatedLines: Int {
        clones.reduce(0) { $0 + ($1.endLine - $1.startLine + 1) }
    }
}

// MARK: - Duplication Detector Configuration

/// Configuration for duplication detection.
public struct DuplicationConfiguration: Sendable {
    /// Minimum tokens to consider as a clone.
    public var minimumTokens: Int

    /// Types of clones to detect.
    public var cloneTypes: Set<CloneType>

    /// Patterns to ignore (regex).
    public var ignoredPatterns: [String]

    /// Minimum similarity for near/semantic clones (0.0-1.0).
    public var minimumSimilarity: Double

    public init(
        minimumTokens: Int = 50,
        cloneTypes: Set<CloneType> = [.exact],
        ignoredPatterns: [String] = [],
        minimumSimilarity: Double = 0.8
    ) {
        self.minimumTokens = minimumTokens
        self.cloneTypes = cloneTypes
        self.ignoredPatterns = ignoredPatterns
        self.minimumSimilarity = minimumSimilarity
    }

    /// Default configuration.
    public static let `default` = DuplicationConfiguration()
}

// MARK: - Duplication Detector

/// Detects code duplication in Swift source files.
public struct DuplicationDetector: Sendable {
    /// Configuration for detection.
    public let configuration: DuplicationConfiguration

    /// The analyzer for parsing files.
    private let analyzer: StaticAnalyzer

    public init(configuration: DuplicationConfiguration = .default) {
        self.configuration = configuration
        self.analyzer = StaticAnalyzer()
    }

    /// Detect clones in the given files.
    ///
    /// - Parameter files: Array of Swift file paths.
    /// - Returns: Array of clone groups found.
    public func detectClones(in files: [String]) async throws -> [CloneGroup] {
        var cloneGroups: [CloneGroup] = []

        if configuration.cloneTypes.contains(.exact) {
            let exactClones = try await detectExactClones(in: files)
            cloneGroups.append(contentsOf: exactClones)
        }

        if configuration.cloneTypes.contains(.near) {
            let nearClones = try await detectNearClones(in: files)
            cloneGroups.append(contentsOf: nearClones)
        }

        if configuration.cloneTypes.contains(.semantic) {
            let semanticClones = try await detectSemanticClones(in: files)
            cloneGroups.append(contentsOf: semanticClones)
        }

        return cloneGroups
    }

    // MARK: - Exact Clone Detection

    private func detectExactClones(in files: [String]) async throws -> [CloneGroup] {
        // Implementation will use token hashing with Rabin-Karp
        // For now, return empty
        []
    }

    // MARK: - Near Clone Detection

    private func detectNearClones(in files: [String]) async throws -> [CloneGroup] {
        // Implementation will normalize identifiers before hashing
        // For now, return empty
        []
    }

    // MARK: - Semantic Clone Detection

    private func detectSemanticClones(in files: [String]) async throws -> [CloneGroup] {
        // Implementation will use AST fingerprinting
        // For now, return empty
        []
    }
}

// MARK: - Duplication Report

/// Report summarizing duplication findings.
public struct DuplicationReport: Sendable, Codable {
    /// Total files analyzed.
    public let filesAnalyzed: Int

    /// Total lines of code.
    public let totalLines: Int

    /// Clone groups found.
    public let cloneGroups: [CloneGroup]

    /// Total duplicated lines.
    public var duplicatedLines: Int {
        cloneGroups.reduce(0) { $0 + $1.duplicatedLines }
    }

    /// Duplication percentage.
    public var duplicationPercentage: Double {
        guard totalLines > 0 else { return 0 }
        return Double(duplicatedLines) / Double(totalLines) * 100
    }

    public init(
        filesAnalyzed: Int,
        totalLines: Int,
        cloneGroups: [CloneGroup]
    ) {
        self.filesAnalyzed = filesAnalyzed
        self.totalLines = totalLines
        self.cloneGroups = cloneGroups
    }
}
