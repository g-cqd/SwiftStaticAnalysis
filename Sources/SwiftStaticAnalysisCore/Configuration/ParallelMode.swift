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
/// - `maximum`: Higher concurrency (`highThroughput` preset) **plus**
///   AsyncChannel-backed streaming with backpressure on the duplication
///   pipeline. Use this when memory headroom is the bottleneck on
///   large codebases (millions of token pairs) — the streaming
///   verifier suspends the producer if a slow consumer would otherwise
///   queue an unbounded result buffer. The 0.2.x README claimed this
///   behaviour but routed `.maximum` through the same plumbing as
///   `.safe`; the 0.3.0-α release actually wires the streaming path.
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

    /// Higher-concurrency execution (`highThroughput` preset) **and**
    /// AsyncChannel-backed streaming on the duplication pipeline.
    /// Results still require sorting at boundaries when determinism
    /// matters.
    case maximum

    /// Whether this mode engages the AsyncChannel-backed streaming
    /// verifier (`BackpressuredChannelStream` under the hood). Currently
    /// only `.maximum` flips this — `.safe` runs TaskGroup with
    /// per-task buffering, `.maximum` adds the streaming sink so a slow
    /// consumer suspends the producer instead of queueing unbounded.
    public var usesStreamingVerifier: Bool {
        switch self {
        case .none, .safe: return false
        case .maximum: return true
        }
    }
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
