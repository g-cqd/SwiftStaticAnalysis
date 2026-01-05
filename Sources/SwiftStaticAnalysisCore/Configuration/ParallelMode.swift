//
//  ParallelMode.swift
//  SwiftStaticAnalysis
//
//  Parallel execution mode for analysis operations.
//  Provides backward compatibility with boolean --parallel flag while enabling
//  future streaming/async-algorithms patterns.
//

import Foundation

import class Foundation.ProcessInfo

// MARK: - ParallelMode

/// Parallel execution mode for analysis operations.
///
/// This enum supports three execution modes with different performance/memory tradeoffs:
/// - `none`: Sequential execution, deterministic, lowest memory usage
/// - `safe`: Current parallel behavior (TaskGroup-based), deterministic via sorting
/// - `maximum`: Maximum parallelism with streaming (future async-algorithms support)
///
/// Example usage in `.swa.json`:
/// ```json
/// {
///   "unused": {
///     "parallelMode": "safe"
///   }
/// }
/// ```
public enum ParallelMode: String, Codable, Sendable, CaseIterable {
    /// Sequential execution. No parallelism. Deterministic.
    /// Best for debugging and minimal memory usage.
    case none

    /// Current parallel behavior (TaskGroup-based). Deterministic output via sorting.
    /// Recommended default for most codebases.
    case safe

    /// Maximum parallelism with async-algorithms streaming.
    /// Enables backpressure and memory-bounded processing for very large codebases.
    /// Results require explicit sorting at boundaries.
    case maximum
}

// MARK: - Backward Compatibility

extension ParallelMode {
    /// Create ParallelMode from legacy boolean parallel flag.
    ///
    /// - Parameter parallel: Legacy parallel flag value.
    /// - Returns: `.safe` if true, `.none` if false.
    public static func from(legacyParallel: Bool) -> ParallelMode {
        legacyParallel ? .safe : .none
    }

    /// Convert to boolean for backward compatibility with existing code.
    public var isParallel: Bool {
        switch self {
        case .none:
            false
        case .safe, .maximum:
            true
        }
    }

    /// Whether this mode uses streaming (async-algorithms).
    public var usesStreaming: Bool {
        self == .maximum
    }
}

// MARK: - ConcurrencyConfiguration Extension

extension ParallelMode {
    /// Convert to ConcurrencyConfiguration for backward compatibility.
    ///
    /// - Parameter maxConcurrency: Optional override for max concurrent operations.
    /// - Returns: Appropriate ConcurrencyConfiguration for this mode.
    public func toConcurrencyConfiguration(maxConcurrency: Int? = nil) -> ConcurrencyConfiguration {
        switch self {
        case .none:
            ConcurrencyConfiguration.serial

        case .safe:
            if let max = maxConcurrency {
                ConcurrencyConfiguration(
                    maxConcurrentFiles: max,
                    maxConcurrentTasks: max * 2
                )
            } else {
                ConcurrencyConfiguration.default
            }

        case .maximum:
            if let max = maxConcurrency {
                ConcurrencyConfiguration(
                    maxConcurrentFiles: max * 2,
                    maxConcurrentTasks: max * 4,
                    batchSize: 200
                )
            } else {
                ConcurrencyConfiguration.highThroughput
            }
        }
    }
}
