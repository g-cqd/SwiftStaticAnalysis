//  UnusedCodeTypes.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore

// MARK: - UnusedReason

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

// MARK: - Confidence

/// Confidence level for unused code detection.
public enum Confidence: String, Sendable, Codable, Comparable {
    /// Definitely unused (private, no references found).
    case high

    /// Likely unused (internal, no visible references).
    case medium

    /// Possibly unused (public API, may be used externally).
    case low

    // MARK: Public

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    // MARK: Private

    private var rank: Int {
        switch self {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }
}

// MARK: - UnusedCode

/// Represents a piece of unused code.
public struct UnusedCode: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        declaration: Declaration,
        reason: UnusedReason,
        confidence: Confidence,
        suggestion: String = "Consider removing this declaration",
    ) {
        self.declaration = declaration
        self.reason = reason
        self.confidence = confidence
        self.suggestion = suggestion
    }

    // MARK: Public

    /// The unused declaration.
    public let declaration: Declaration

    /// Reason it's considered unused.
    public let reason: UnusedReason

    /// Confidence level.
    public let confidence: Confidence

    /// Suggested action.
    public let suggestion: String
}

// MARK: - DetectionMode

/// Mode for unused code detection.
public enum DetectionMode: String, Sendable, Codable {
    /// Simple reference counting (fast, approximate).
    case simple

    /// Reachability graph analysis (more accurate, considers entry points).
    case reachability

    /// IndexStoreDB-based (most accurate, requires project build).
    case indexStore
}

// MARK: - UnusedCodeReport

/// Report summarizing unused code findings.
public struct UnusedCodeReport: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        filesAnalyzed: Int,
        totalDeclarations: Int,
        unusedItems: [UnusedCode],
    ) {
        self.filesAnalyzed = filesAnalyzed
        self.totalDeclarations = totalDeclarations
        self.unusedItems = unusedItems
    }

    // MARK: Public

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
}
