//  TaskBackedAsyncStreamTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import SwiftStaticAnalysisCore

@Suite("TaskBackedAsyncStream Tests")
struct TaskBackedAsyncStreamTests {
    @Test("makeStream cancels producer when iteration terminates early")
    func makeStreamCancelsProducerOnEarlyTermination() async {
        let probe = CancellationProbe()

        do {
            let stream = TaskBackedAsyncStream.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            ) { continuation in
                await withTaskCancellationHandler {
                    continuation.yield(1)

                    while !Task.isCancelled {
                        await Task.yield()
                    }

                    continuation.finish()
                } onCancel: {
                    Task {
                        await probe.markCancelled()
                    }
                }
            }

            let consumer = Task {
                for await _ in stream {
                    await probe.markReceivedValue()

                    while !Task.isCancelled {
                        await Task.yield()
                    }

                    return
                }
            }

            for _ in 0..<1_000 where !(await probe.didReceiveValue) {
                await Task.yield()
            }

            #expect(await probe.didReceiveValue)

            consumer.cancel()
            await consumer.value
        }

        for _ in 0..<1_000 where !(await probe.wasCancelled) {
            await Task.yield()
        }

        #expect(await probe.wasCancelled)
    }
}

private actor CancellationProbe {
    private(set) var didReceiveValue = false
    private(set) var wasCancelled = false

    func markReceivedValue() {
        didReceiveValue = true
    }

    func markCancelled() {
        wasCancelled = true
    }
}
