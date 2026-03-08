//  TaskBackedAsyncStream.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - TaskBackedAsyncStream

/// Creates `AsyncStream` values backed by a cancellable task.
public enum TaskBackedAsyncStream {
    /// Create a stream whose producer task is cancelled when iteration terminates early.
    ///
    /// - Parameters:
    ///   - bufferingPolicy: Stream buffering policy.
    ///   - operation: Async producer operation. The operation is responsible for finishing the continuation.
    /// - Returns: An async stream backed by a cancellable task.
    public static func makeStream<Element>(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded,
        operation: @escaping @Sendable (AsyncStream<Element>.Continuation) async -> Void
    ) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let task = Task {
                await operation(continuation)
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - TaskCooperation

/// Cooperative cancellation helpers for CPU-bound async work.
public enum TaskCooperation {
    /// Yield periodically and report whether the current task should stop.
    ///
    /// - Parameters:
    ///   - iteration: Current loop iteration counter, starting at 1.
    ///   - interval: Yield cadence. Defaults to 256 iterations.
    /// - Returns: `true` when the current task is cancelled and the caller should stop.
    public static func checkpoint(
        iteration: Int,
        every interval: Int = 256
    ) async -> Bool {
        if Task.isCancelled {
            return true
        }

        guard interval > 0, iteration.isMultiple(of: interval) else {
            return false
        }

        await Task.yield()
        return Task.isCancelled
    }
}
