//  ParallelMode.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - ParallelMode

/// Parallel execution mode for analysis operations.
///
/// This enum supports three execution modes with different performance/memory
/// tradeoffs:
/// - `none`: Sequential execution, deterministic, lowest memory usage.
/// - `safe`: Default parallel behaviour (TaskGroup-based), deterministic via
///   per-task result sorting.
/// - `maximum`: Higher concurrency (`highThroughput` preset). Note that
///   `.safe` and `.maximum` differ only in their `ConcurrencyConfiguration`
///   shape (max files / max tasks); the streaming/backpressure path is
///   reached via explicit streaming APIs (e.g. `StreamingVerifier`), not by
///   choosing `.maximum`. See `TaskBackedAsyncStream` for the buffering
///   policy details.
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

    /// Higher-concurrency execution (`highThroughput` preset). Same
    /// task-group plumbing as `.safe`; results still require sorting at
    /// boundaries when determinism matters.
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
                    maxConcurrentTasks: max * 4
                )
            } else {
                ConcurrencyConfiguration.highThroughput
            }
        }
    }
}
