//  TaskBackedAsyncStream.swift
//  SwiftStaticAnalysis
//  MIT License

import AsyncAlgorithms
import Foundation

// MARK: - TaskBackedAsyncStream

/// Creates `AsyncStream` values backed by a cancellable task.
public enum TaskBackedAsyncStream {
    /// Default in-flight buffer for `makeStream`. 256 elements caps memory
    /// pressure for streaming analysis results without throttling typical
    /// producers.
    public static let defaultBufferSize = 256

    /// Create a stream whose producer task is cancelled when iteration terminates early.
    ///
    /// The default buffering policy is `.bufferingNewest(defaultBufferSize)`
    /// rather than `.unbounded`: with a slow consumer, the producer would
    /// otherwise keep buffering forever, defeating the "memory-bounded"
    /// promise made by `ParallelMode.maximum`. Note that `.bufferingNewest`
    /// is "buffer + drop oldest under overflow", not true backpressure —
    /// callers needing the producer to *suspend* when the buffer is full
    /// should use `AsyncChannel` from swift-async-algorithms.
    ///
    /// - Parameters:
    ///   - bufferingPolicy: Stream buffering policy.
    ///   - operation: Async producer operation. The operation is responsible
    ///     for finishing the continuation.
    /// - Returns: An async stream backed by a cancellable task.
    public static func makeStream<Element>(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy =
            .bufferingNewest(TaskBackedAsyncStream.defaultBufferSize),
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

// MARK: - BackpressuredChannelStream

/// Backbone for streaming async results with **true backpressure**.
///
/// Wraps `AsyncChannel` from swift-async-algorithms with the same
/// "producer task cancelled when iteration terminates" semantics as
/// `TaskBackedAsyncStream`. Unlike `AsyncStream` with `.bufferingNewest`,
/// the producer **suspends** when the consumer hasn't drained the latest
/// element. This makes "memory-bounded streaming" honest at the cost of
/// limiting throughput to whatever the consumer can accept.
///
/// Use when:
/// - `ParallelMode.maximum` is selected and the caller wants memory-bounded
///   processing.
/// - The result stream is expensive enough that dropping elements would
///   lose work (e.g. verified clone pairs that won't be recomputed).
///
/// Avoid when:
/// - The consumer is uniformly fast; the buffer-and-drop semantics of
///   `TaskBackedAsyncStream` are cheaper.
public enum BackpressuredChannelStream {
    /// Create an `AsyncChannel` plus a producer `Task` that fills it.
    ///
    /// Cancellation propagation (post 0.3.0-α):
    ///
    /// - The producer is spawned as a structured `Task` from the caller's
    ///   context, so **parent-task cancellation** propagates via
    ///   `Task.isCancelled` at the producer's async checkpoints.
    /// - We additionally wrap the producer in `withTaskCancellationHandler`
    ///   so the `onCancel:` callback finishes the channel **immediately**,
    ///   regardless of where in the operation the cancellation arrives.
    ///   Without that, a consumer that drops its iterator would have to
    ///   wait for the producer to reach its next `Task.isCancelled`
    ///   checkpoint before the channel closed — measurable as stale
    ///   results piling up after the consumer has stopped reading.
    /// - On normal completion the operation finishes the channel itself
    ///   (or the trailing `channel.finish()` below does it).
    ///
    /// The producer closure receives the channel; it should send via
    /// `await channel.send(_:)` (suspends on backpressure) and call
    /// `channel.finish()` when done.
    ///
    /// - Parameter operation: Async producer that pushes elements through
    ///   the channel and finishes it.
    /// - Returns: The channel for the consumer to iterate.
    @discardableResult
    public static func makeChannel<Element: Sendable>(
        operation: @escaping @Sendable (AsyncChannel<Element>) async -> Void
    ) -> AsyncChannel<Element> {
        let channel = AsyncChannel<Element>()
        Task {
            await withTaskCancellationHandler {
                await operation(channel)
            } onCancel: {
                // Immediate close so the consumer's `for await` loop
                // returns on the next iteration even if the operation
                // closure is suspended in `await channel.send(_:)`.
                channel.finish()
            }
            channel.finish()
        }
        return channel
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
