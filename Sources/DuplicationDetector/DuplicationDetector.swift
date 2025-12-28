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

    /// The file parser.
    private let parser: SwiftFileParser

    public init(configuration: DuplicationConfiguration = .default) {
        self.configuration = configuration
        self.parser = SwiftFileParser()
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

        // Add code snippets to all clones
        return try await addCodeSnippets(to: cloneGroups, files: files)
    }

    // MARK: - Exact Clone Detection

    private func detectExactClones(in files: [String]) async throws -> [CloneGroup] {
        // Extract token sequences from all files
        let sequences = try await extractTokenSequences(from: files)

        // Run exact clone detection
        let detector = ExactCloneDetector(minimumTokens: configuration.minimumTokens)
        return detector.detect(in: sequences)
    }

    // MARK: - Near Clone Detection

    private func detectNearClones(in files: [String]) async throws -> [CloneGroup] {
        // Extract token sequences from all files
        let sequences = try await extractTokenSequences(from: files)

        // Run near clone detection with normalized tokens
        let detector = NearCloneDetector(
            minimumTokens: configuration.minimumTokens,
            minimumSimilarity: configuration.minimumSimilarity
        )
        return detector.detect(in: sequences)
    }

    // MARK: - Semantic Clone Detection

    private func detectSemanticClones(in files: [String]) async throws -> [CloneGroup] {
        // Run semantic clone detection with AST fingerprinting
        let detector = SemanticCloneDetector(
            minimumNodes: configuration.minimumTokens / 5, // Roughly 5 tokens per node
            minimumSimilarity: configuration.minimumSimilarity
        )
        return try await detector.detect(in: files)
    }

    // MARK: - Helpers

    /// Extract token sequences from files.
    private func extractTokenSequences(from files: [String]) async throws -> [TokenSequence] {
        let extractor = TokenSequenceExtractor()
        var sequences: [TokenSequence] = []

        for file in files {
            let tree = try await parser.parse(file)
            let source = try String(contentsOfFile: file, encoding: .utf8)
            let sequence = extractor.extract(from: tree, file: file, source: source)
            sequences.append(sequence)
        }

        return sequences
    }

    /// Add code snippets to clone groups.
    private func addCodeSnippets(
        to groups: [CloneGroup],
        files: [String]
    ) async throws -> [CloneGroup] {
        // Cache file contents
        var fileContents: [String: [String]] = [:]
        for file in files {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            fileContents[file] = source.components(separatedBy: .newlines)
        }

        return groups.map { group in
            let clonesWithSnippets = group.clones.map { clone -> Clone in
                let snippet: String
                if let lines = fileContents[clone.file] {
                    let start = max(0, clone.startLine - 1)
                    let end = min(lines.count, clone.endLine)
                    if start < end {
                        snippet = lines[start..<end].joined(separator: "\n")
                    } else {
                        snippet = ""
                    }
                } else {
                    snippet = ""
                }

                return Clone(
                    file: clone.file,
                    startLine: clone.startLine,
                    endLine: clone.endLine,
                    tokenCount: clone.tokenCount,
                    codeSnippet: snippet
                )
            }

            return CloneGroup(
                type: group.type,
                clones: clonesWithSnippets,
                similarity: group.similarity,
                fingerprint: group.fingerprint
            )
        }
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
