//
//  ConcurrencyConfiguration.swift
//  SwiftStaticAnalysis
//
//  Configuration for parallel processing limits and concurrency control.
//

import Foundation

// MARK: - ConcurrencyConfiguration

/// Configuration for parallel processing in analysis operations.
public struct ConcurrencyConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        maxConcurrentFiles: Int? = nil,
        maxConcurrentTasks: Int? = nil,
        enableParallelProcessing: Bool = true,
        batchSize: Int = 100,
    ) {
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        self.maxConcurrentFiles = maxConcurrentFiles ?? processorCount
        self.maxConcurrentTasks = maxConcurrentTasks ?? processorCount * 2
        self.enableParallelProcessing = enableParallelProcessing
        self.batchSize = batchSize
    }

    // MARK: Public

    /// Default configuration based on system capabilities.
    public static let `default` = Self()

    /// Single-threaded configuration (for debugging or testing).
    public static let serial = Self(
        maxConcurrentFiles: 1,
        maxConcurrentTasks: 1,
        enableParallelProcessing: false,
    )

    /// High-throughput configuration for powerful machines.
    public static let highThroughput = Self(
        maxConcurrentFiles: ProcessInfo.processInfo.activeProcessorCount * 2,
        maxConcurrentTasks: ProcessInfo.processInfo.activeProcessorCount * 4,
        batchSize: 200,
    )

    /// Conservative configuration for memory-constrained environments.
    public static let conservative = Self(
        maxConcurrentFiles: max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        maxConcurrentTasks: ProcessInfo.processInfo.activeProcessorCount,
        batchSize: 50,
    )

    /// Maximum number of files to process concurrently.
    public let maxConcurrentFiles: Int

    /// Maximum number of analysis tasks to run concurrently.
    public let maxConcurrentTasks: Int

    /// Whether to enable parallel processing (can be disabled for debugging).
    public let enableParallelProcessing: Bool

    /// Chunk size for batching operations.
    public let batchSize: Int
}

// MARK: - AsyncSemaphore

/// A simple async semaphore for limiting concurrent operations.
public actor AsyncSemaphore {
    // MARK: Lifecycle

    public init(value: Int) {
        count = value
    }

    // MARK: Public

    /// Current number of available permits.
    public var available: Int {
        count
    }

    /// Wait to acquire a permit.
    public func wait() async {
        // swiftlint:disable:next empty_count
        if count > 0 {
            count -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Signal that a permit is available.
    public func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }

    /// Try to acquire a permit without waiting.
    public func tryWait() -> Bool {
        // swiftlint:disable:next empty_count
        if count > 0 {
            count -= 1
            return true
        }
        return false
    }

    // MARK: Private

    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
}

// MARK: - ParallelProcessor

/// Utilities for parallel file processing with concurrency limits.
public enum ParallelProcessor {
    /// Process items in parallel with a concurrency limit using batching.
    ///
    /// - Parameters:
    ///   - items: Items to process.
    ///   - maxConcurrency: Maximum concurrent tasks (used as batch size).
    ///   - operation: Async operation to perform on each item.
    /// - Returns: Array of results in same order as input.
    public static func map<T, R: Sendable>(
        _ items: [T],
        maxConcurrency: Int,
        operation: @Sendable @escaping (T) async throws -> R,
    ) async throws -> [R] where T: Sendable {
        guard !items.isEmpty else { return [] }

        // For small batches, process with simple TaskGroup
        if items.count <= maxConcurrency {
            return try await withThrowingTaskGroup(of: (Int, R).self) { group in
                for (index, item) in items.enumerated() {
                    group.addTask {
                        let result = try await operation(item)
                        return (index, result)
                    }
                }

                var indexedResults: [(Int, R)] = []
                indexedResults.reserveCapacity(items.count)
                for try await result in group {
                    indexedResults.append(result)
                }

                return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }

        // For larger batches, process in chunks to limit concurrency
        var allResults: [R?] = Array(repeating: nil, count: items.count)
        let batchSize = maxConcurrency

        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, items.count)
            let batch = Array(items[batchStart ..< batchEnd])

            try await withThrowingTaskGroup(of: (Int, R).self) { group in
                for (localIndex, item) in batch.enumerated() {
                    let globalIndex = batchStart + localIndex
                    group.addTask {
                        let result = try await operation(item)
                        return (globalIndex, result)
                    }
                }

                for try await (index, result) in group {
                    allResults[index] = result
                }
            }
        }

        return allResults.compactMap(\.self)
    }

    /// Process items in parallel, collecting only successful results.
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

        var results: [R] = []

        // Process in batches
        let batchSize = max(1, maxConcurrency)
        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, items.count)
            let batch = Array(items[batchStart ..< batchEnd])

            await withTaskGroup(of: R?.self) { group in
                for item in batch {
                    group.addTask {
                        await operation(item)
                    }
                }

                for await result in group {
                    if let result {
                        results.append(result)
                    }
                }
            }
        }

        return results
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

        // Process in batches
        let batchSize = max(1, maxConcurrency)
        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, items.count)
            let batch = Array(items[batchStart ..< batchEnd])

            try await withThrowingTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask {
                        try await operation(item)
                    }
                }

                try await group.waitForAll()
            }
        }
    }
}
