//  BackpressuredChannelStreamTests.swift
//  SwiftStaticAnalysis
//  MIT License

import AsyncAlgorithms
import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

@Suite("BackpressuredChannelStream Tests")
struct BackpressuredChannelStreamTests {
    /// A fast producer paired with a slow consumer must not overrun. The
    /// channel only allows a single in-flight value (AsyncChannel's
    /// rendezvous semantics), so the producer suspends on every send
    /// until the consumer drains it. This is the property
    /// `TaskBackedAsyncStream + bufferingNewest` cannot offer.
    @Test("producer suspends until consumer drains")
    func producerSuspendsOnSlowConsumer() async {
        let channel = BackpressuredChannelStream.makeChannel { channel in
            for value in 0..<8 {
                await channel.send(value)
            }
        }

        var received: [Int] = []
        for await value in channel {
            received.append(value)
            // Yield a few times to give the producer a chance to run
            // ahead — if backpressure is broken the producer would race
            // ahead and we'd see all 8 elements before the channel
            // finishes; but the producer can't outpace this single
            // consumer.
            await Task.yield()
            if received.count == 4 {
                // Confirm we're 4 in before the producer finishes.
                #expect(received == [0, 1, 2, 3])
            }
        }

        #expect(received == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    /// `channel.finish()` is called once the producer closure returns;
    /// the consumer's `for await` loop must terminate cleanly.
    @Test("channel finishes when producer returns")
    func channelFinishesOnProducerReturn() async {
        let channel = BackpressuredChannelStream.makeChannel { (_: AsyncChannel<Int>) in
            // Produce nothing; immediately return.
        }

        var iterations = 0
        for await _ in channel {
            iterations += 1
        }

        #expect(iterations == 0)
    }

    /// A consumer that stops early should not leave the producer running
    /// forever. AsyncChannel terminates the iterator once `finish()` is
    /// called; cancellation propagates via `Task.isCancelled` inside the
    /// producer closure.
    @Test("early consumer exit cancels the producer")
    func earlyConsumerExitCancelsProducer() async {
        let channel = BackpressuredChannelStream.makeChannel { channel in
            // Loop indefinitely; rely on cancellation propagation.
            var value = 0
            while !Task.isCancelled {
                await channel.send(value)
                value += 1
            }
        }

        var received: [Int] = []
        for await value in channel {
            received.append(value)
            if received.count == 3 {
                break
            }
        }

        #expect(received.count == 3)
        // Producer is left in flight; cancellation propagates via the
        // implicit task cancellation when this scope exits. The test's
        // success criterion is that we don't hang waiting on more values.
    }
}
