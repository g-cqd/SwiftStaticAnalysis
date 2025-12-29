//
//  ConfidenceCalculator.swift
//  SwiftStaticAnalysis
//
//  Shared utilities for calculating confidence levels.
//

import SwiftStaticAnalysisCore

// MARK: - Declaration Confidence Extension

public extension Declaration {
    /// Determine confidence level for unused code detection based on access level.
    ///
    /// - Returns: Confidence level based on the declaration's access level.
    var unusedConfidence: Confidence {
        switch accessLevel {
        case .fileprivate,
             .private:
            .high
        case .internal,
             .package:
            .medium
        case .open,
             .public:
            .low
        }
    }
}
