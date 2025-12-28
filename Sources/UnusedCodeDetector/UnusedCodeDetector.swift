//
//  UnusedCodeDetector.swift
//  SwiftStaticAnalysis
//
//  Unused code detection module.
//

import Foundation
import SwiftStaticAnalysisCore

// MARK: - Unused Reason

/// Reasons why code is considered unused.
public enum UnusedReason: String, Sendable, Codable {
    /// Declaration is never referenced anywhere.
    case neverReferenced

    /// Variable is assigned but never read.
    case onlyAssigned

    /// Only referenced within its own implementation.
    case onlySelfReferenced

    /// Import statement is not used.
    case importNotUsed

    /// Parameter is never used in function body.
    case parameterUnused
}

// MARK: - Confidence Level

/// Confidence level for unused code detection.
public enum Confidence: String, Sendable, Codable, Comparable {
    /// Definitely unused (private, no references found).
    case high

    /// Likely unused (internal, no visible references).
    case medium

    /// Possibly unused (public API, may be used externally).
    case low

    private var rank: Int {
        switch self {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Unused Code

/// Represents a piece of unused code.
public struct UnusedCode: Sendable, Codable {
    /// The unused declaration.
    public let declaration: Declaration

    /// Reason it's considered unused.
    public let reason: UnusedReason

    /// Confidence level.
    public let confidence: Confidence

    /// Suggested action.
    public let suggestion: String

    public init(
        declaration: Declaration,
        reason: UnusedReason,
        confidence: Confidence,
        suggestion: String = "Consider removing this declaration"
    ) {
        self.declaration = declaration
        self.reason = reason
        self.confidence = confidence
        self.suggestion = suggestion
    }
}

// MARK: - Unused Code Configuration

/// Configuration for unused code detection.
public struct UnusedCodeConfiguration: Sendable {
    /// Detect unused variables.
    public var detectVariables: Bool

    /// Detect unused functions.
    public var detectFunctions: Bool

    /// Detect unused types.
    public var detectTypes: Bool

    /// Detect unused imports.
    public var detectImports: Bool

    /// Detect unused parameters.
    public var detectParameters: Bool

    /// Ignore public API (may be used externally).
    public var ignorePublicAPI: Bool

    /// Use IndexStoreDB for accurate detection.
    public var useIndexStore: Bool

    /// Path to the index store (usually .build/...).
    public var indexStorePath: String?

    /// Minimum confidence level to report.
    public var minimumConfidence: Confidence

    /// Patterns to ignore (regex for declaration names).
    public var ignoredPatterns: [String]

    public init(
        detectVariables: Bool = true,
        detectFunctions: Bool = true,
        detectTypes: Bool = true,
        detectImports: Bool = true,
        detectParameters: Bool = true,
        ignorePublicAPI: Bool = true,
        useIndexStore: Bool = false,
        indexStorePath: String? = nil,
        minimumConfidence: Confidence = .medium,
        ignoredPatterns: [String] = []
    ) {
        self.detectVariables = detectVariables
        self.detectFunctions = detectFunctions
        self.detectTypes = detectTypes
        self.detectImports = detectImports
        self.detectParameters = detectParameters
        self.ignorePublicAPI = ignorePublicAPI
        self.useIndexStore = useIndexStore
        self.indexStorePath = indexStorePath
        self.minimumConfidence = minimumConfidence
        self.ignoredPatterns = ignoredPatterns
    }

    /// Default configuration.
    public static let `default` = UnusedCodeConfiguration()
}

// MARK: - Unused Code Detector

/// Detects unused code in Swift source files.
public struct UnusedCodeDetector: Sendable {
    /// Configuration for detection.
    public let configuration: UnusedCodeConfiguration

    /// The analyzer for parsing files.
    private let analyzer: StaticAnalyzer

    public init(configuration: UnusedCodeConfiguration = .default) {
        self.configuration = configuration
        self.analyzer = StaticAnalyzer()
    }

    /// Detect unused code in the given files.
    ///
    /// - Parameter files: Array of Swift file paths.
    /// - Returns: Array of unused code findings.
    public func detectUnused(in files: [String]) async throws -> [UnusedCode] {
        // Use IndexStore if configured
        if configuration.useIndexStore {
            return try await detectUnusedWithIndexStore(in: files)
        }

        // Fall back to SwiftSyntax-only analysis
        return try await detectUnusedWithSyntax(in: files)
    }

    /// Detect unused code using IndexStoreDB (accurate but requires project build).
    private func detectUnusedWithIndexStore(in files: [String]) async throws -> [UnusedCode] {
        // Find or use configured index store path
        let indexStorePath: String
        if let configured = configuration.indexStorePath {
            indexStorePath = configured
        } else {
            // Try to find it automatically
            guard let found = findIndexStorePath(for: files) else {
                // Fall back to syntax-only analysis
                return try await detectUnusedWithSyntax(in: files)
            }
            indexStorePath = found
        }

        // Use the index store based detector
        let detector = IndexStoreBasedDetector(configuration: configuration)
        let results = try detector.detect(in: files, indexStorePath: indexStorePath)

        return results
            .filter { $0.confidence >= configuration.minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Find the index store path for the given files.
    private func findIndexStorePath(for files: [String]) -> String? {
        guard let firstFile = files.first else { return nil }

        // Walk up from the first file to find project root
        var current = URL(fileURLWithPath: firstFile).deletingLastPathComponent()
        let maxDepth = 10

        for _ in 0..<maxDepth {
            // Check for Package.swift (Swift package)
            let packageSwift = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return IndexStorePathFinder.findIndexStorePath(in: current.path)
            }

            // Check for .xcodeproj
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
               contents.contains(where: { $0.hasSuffix(".xcodeproj") }) {
                return IndexStorePathFinder.findIndexStorePath(in: current.path)
            }

            current = current.deletingLastPathComponent()
        }

        return nil
    }

    /// Detect unused code using SwiftSyntax only (fast but approximate).
    private func detectUnusedWithSyntax(in files: [String]) async throws -> [UnusedCode] {
        // Analyze all files
        let result = try await analyzer.analyze(files)

        var unusedItems: [UnusedCode] = []

        // Build a set of all referenced identifiers
        let referencedIdentifiers = result.references.uniqueIdentifiers

        // Check each declaration
        for declaration in result.declarations.declarations {
            // Skip based on configuration
            if !shouldCheck(declaration) {
                continue
            }

            // Check if referenced
            let isReferenced = referencedIdentifiers.contains(declaration.name)

            if !isReferenced {
                let confidence = determineConfidence(for: declaration)

                // Skip if below minimum confidence
                if confidence < configuration.minimumConfidence {
                    continue
                }

                let reason = determineReason(for: declaration, result: result)
                let suggestion = generateSuggestion(for: declaration, reason: reason)

                unusedItems.append(UnusedCode(
                    declaration: declaration,
                    reason: reason,
                    confidence: confidence,
                    suggestion: suggestion
                ))
            }
        }

        // Check imports if enabled
        if configuration.detectImports {
            let unusedImports = detectUnusedImports(result: result)
            unusedItems.append(contentsOf: unusedImports)
        }

        return unusedItems.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Private Helpers

    private func shouldCheck(_ declaration: Declaration) -> Bool {
        // Check if this kind should be detected
        switch declaration.kind {
        case .variable, .constant:
            guard configuration.detectVariables else { return false }
        case .function, .method:
            guard configuration.detectFunctions else { return false }
        case .class, .struct, .enum, .protocol:
            guard configuration.detectTypes else { return false }
        case .parameter:
            guard configuration.detectParameters else { return false }
        case .import:
            return false // Handled separately
        default:
            break
        }

        // Check if public API should be ignored
        if configuration.ignorePublicAPI && declaration.accessLevel >= .public {
            return false
        }

        // Check ignored patterns
        for pattern in configuration.ignoredPatterns {
            if let regex = try? Regex(pattern),
               declaration.name.contains(regex) {
                return false
            }
        }

        return true
    }

    private func determineConfidence(for declaration: Declaration) -> Confidence {
        switch declaration.accessLevel {
        case .private, .fileprivate:
            return .high
        case .internal, .package:
            return .medium
        case .public, .open:
            return .low
        }
    }

    private func determineReason(
        for declaration: Declaration,
        result: AnalysisResult
    ) -> UnusedReason {
        switch declaration.kind {
        case .variable, .constant:
            // Check if only written to
            let refs = result.references.find(identifier: declaration.name)
            let hasReads = refs.contains { $0.context == .read }
            if !hasReads && refs.contains(where: { $0.context == .write }) {
                return .onlyAssigned
            }
            return .neverReferenced

        case .parameter:
            return .parameterUnused

        case .import:
            return .importNotUsed

        default:
            return .neverReferenced
        }
    }

    private func generateSuggestion(
        for declaration: Declaration,
        reason: UnusedReason
    ) -> String {
        switch reason {
        case .neverReferenced:
            return "Consider removing unused \(declaration.kind.rawValue) '\(declaration.name)'"
        case .onlyAssigned:
            return "Variable '\(declaration.name)' is assigned but never read"
        case .onlySelfReferenced:
            return "'\(declaration.name)' is only used within its own implementation"
        case .importNotUsed:
            return "Import '\(declaration.name)' is not used"
        case .parameterUnused:
            return "Parameter '\(declaration.name)' is never used; consider renaming to '_'"
        }
    }

    private func detectUnusedImports(result: AnalysisResult) -> [UnusedCode] {
        var unusedImports: [UnusedCode] = []

        // Get all import declarations
        let imports = result.declarations.find(kind: .import)

        // For each import, check if any reference uses that module
        for importDecl in imports {
            let moduleName = importDecl.name

            // Check if any type reference might be from this module
            // This is approximate without semantic analysis
            let potentiallyUsed = result.references.references.contains { ref in
                ref.context == .typeAnnotation ||
                ref.context == .inheritance ||
                ref.context == .call
            }

            // For now, mark as low confidence since we can't be certain
            if !potentiallyUsed {
                unusedImports.append(UnusedCode(
                    declaration: importDecl,
                    reason: .importNotUsed,
                    confidence: .low,
                    suggestion: "Import '\(moduleName)' may not be used"
                ))
            }
        }

        return unusedImports
    }
}

// MARK: - Unused Code Report

/// Report summarizing unused code findings.
public struct UnusedCodeReport: Sendable, Codable {
    /// Total files analyzed.
    public let filesAnalyzed: Int

    /// Total declarations analyzed.
    public let totalDeclarations: Int

    /// Unused code items found.
    public let unusedItems: [UnusedCode]

    /// Summary by kind.
    public var summaryByKind: [String: Int] {
        var summary: [String: Int] = [:]
        for item in unusedItems {
            summary[item.declaration.kind.rawValue, default: 0] += 1
        }
        return summary
    }

    /// Summary by confidence.
    public var summaryByConfidence: [String: Int] {
        var summary: [String: Int] = [:]
        for item in unusedItems {
            summary[item.confidence.rawValue, default: 0] += 1
        }
        return summary
    }

    public init(
        filesAnalyzed: Int,
        totalDeclarations: Int,
        unusedItems: [UnusedCode]
    ) {
        self.filesAnalyzed = filesAnalyzed
        self.totalDeclarations = totalDeclarations
        self.unusedItems = unusedItems
    }
}
