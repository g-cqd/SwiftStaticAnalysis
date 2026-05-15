//  ConcurrencyConfiguration.swift
//  SwiftStaticAnalysis
//  MIT License

import Algorithms
import Foundation

// MARK: - ConcurrencyConfiguration

/// Configuration for parallel processing in analysis operations.
///
/// Setting `maxConcurrentFiles == 1` (and `maxConcurrentTasks == 1`) forces
/// serial execution. The previous `enableParallelProcessing` flag and the
/// unused `batchSize` field were removed in 0.2.0 — they had no effect on
/// the actual `ParallelProcessor` codepaths, which key off `maxConcurrency`
/// alone.
public struct ConcurrencyConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        maxConcurrentFiles: Int? = nil,
        maxConcurrentTasks: Int? = nil,
    ) {
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        self.maxConcurrentFiles = maxConcurrentFiles ?? processorCount
        self.maxConcurrentTasks = maxConcurrentTasks ?? processorCount * 2
    }

    // MARK: Public

    /// Default configuration based on system capabilities.
    public static let `default` = Self()

    /// Single-threaded configuration (for debugging or testing).
    public static let serial = Self(
        maxConcurrentFiles: 1,
        maxConcurrentTasks: 1,
    )

    /// High-throughput configuration for powerful machines.
    public static let highThroughput = Self(
        maxConcurrentFiles: ProcessInfo.processInfo.activeProcessorCount * 2,
        maxConcurrentTasks: ProcessInfo.processInfo.activeProcessorCount * 4,
    )

    /// Conservative configuration for memory-constrained environments.
    public static let conservative = Self(
        maxConcurrentFiles: max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        maxConcurrentTasks: ProcessInfo.processInfo.activeProcessorCount,
    )

    /// Maximum number of files to process concurrently. Setting this to 1
    /// forces serial execution end-to-end.
    public let maxConcurrentFiles: Int

    /// Maximum number of analysis tasks to run concurrently.
    public let maxConcurrentTasks: Int
}

// MARK: - ParallelProcessor

/// Utilities for parallel file processing with concurrency limits.
public enum ParallelProcessor {
    /// Process items in parallel with a strict concurrency cap.
    ///
    /// Uses the streaming-bounded pattern (start `maxConcurrency` tasks,
    /// add a new one each time one completes) — no batch-barriers, so
    /// fast items don't sit idle waiting for a slow neighbour to finish
    /// its chunk. The pattern matches
    /// `ZeroCopyParser.extractParallel(from:maxConcurrency:)`.
    ///
    /// - Parameters:
    ///   - items: Items to process.
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - operation: Async operation to perform on each item.
    /// - Returns: Array of results in same order as input.
    public static func map<T, R: Sendable>(
        _ items: [T],
        maxConcurrency: Int,
        operation: @Sendable @escaping (T) async throws -> R,
    ) async throws -> [R] where T: Sendable {
        guard !items.isEmpty else { return [] }
        let cap = max(1, maxConcurrency)

        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var iterator = items.enumerated().makeIterator()
            var inFlight = 0

            // Prime up to the concurrency cap.
            while inFlight < cap, let next = iterator.next() {
                let (index, item) = next
                group.addTask { (index, try await operation(item)) }
                inFlight += 1
            }

            // Drain completions, replacing each finished slot with the
            // next pending item. Order-preserving via `index`.
            var indexedResults: [(Int, R)] = []
            indexedResults.reserveCapacity(items.count)
            while let result = try await group.next() {
                indexedResults.append(result)
                inFlight -= 1
                if let next = iterator.next() {
                    let (index, item) = next
                    group.addTask { (index, try await operation(item)) }
                    inFlight += 1
                }
            }
            return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Process items in parallel, collecting only successful results.
    ///
    /// Uses the streaming-bounded pattern (no batch barriers) so the
    /// `maxConcurrency` cap is tracked continuously rather than re-set
    /// at every chunk boundary.
    ///
    /// - Parameters:
    ///   - items: Items to process.
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - operation: Async operation to perform on each item.
    /// - Returns: Array of successful results (order not guaranteed).
    public static func compactMap<T, R: Sendable>(
        _ items: [T],
        maxConcurrency: Int,
        operation: @Sendable @escaping (T) async -> R?,
    ) async -> [R] where T: Sendable {
        guard !items.isEmpty else { return [] }
        let cap = max(1, maxConcurrency)

        return await withTaskGroup(of: R?.self) { group in
            var iterator = items.makeIterator()
            var inFlight = 0

            while inFlight < cap, let item = iterator.next() {
                group.addTask { await operation(item) }
                inFlight += 1
            }

            var results: [R] = []
            while let result = await group.next() {
                inFlight -= 1
                if let result {
                    results.append(result)
                }
                if let item = iterator.next() {
                    group.addTask { await operation(item) }
                    inFlight += 1
                }
            }
            return results
        }
    }

    /// Process items in parallel for side effects only.
    ///
    /// - Parameters:
    ///   - items: Items to process.
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - operation: Async operation to perform on each item.
    public static func forEach<T>(
        _ items: [T],
        maxConcurrency: Int,
        operation: @Sendable @escaping (T) async throws -> Void,
    ) async throws where T: Sendable {
        guard !items.isEmpty else { return }

        // Process in batches.
        //
        // `withThrowingDiscardingTaskGroup` is the right shape here:
        // results are `Void`, so we don't pay for the per-task result
        // slot that `withThrowingTaskGroup(of: Void.self)` allocates,
        // and any throw cancels siblings + propagates out of the group
        // automatically (no explicit `waitForAll`).
        let batchSize = max(1, maxConcurrency)
        for chunk in items.chunks(ofCount: batchSize) {
            try await withThrowingDiscardingTaskGroup { group in
                for item in chunk {
                    group.addTask {
                        try await operation(item)
                    }
                }
            }
        }
    }
}
