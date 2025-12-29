//
//  ConfidenceCalculator.swift
//  SwiftStaticAnalysis
//
//  Shared utilities for calculating confidence levels.
//

import SwiftStaticAnalysisCore

// MARK: - Declaration Confidence Extension

extension Declaration {
    /// Determine confidence level for unused code detection based on access level.
    ///
    /// - Returns: Confidence level based on the declaration's access level.
    public var unusedConfidence: Confidence {
        switch accessLevel {
        case .private, .fileprivate:
            return .high
        case .internal, .package:
            return .medium
        case .public, .open:
            return .low
        }
    }
}
