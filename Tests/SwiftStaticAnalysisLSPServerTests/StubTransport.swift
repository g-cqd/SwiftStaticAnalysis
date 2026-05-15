//  StubTransport.swift
//  SwiftStaticAnalysisLSPServerTests
//  MIT License

import Foundation
import Synchronization

@testable import SwiftStaticAnalysisLSPServer

// MARK: - StubTransport

/// In-memory `LSPTransport` for unit tests. Exposes:
/// - `enqueueRead(_:)`: push a JSON envelope to be returned by the
///   next `readMessage()` call.
/// - `writtenMessages`: snapshot of every message the server has
///   written (in send order).
///
/// The cage pattern: every mutable field lives inside a private
/// reference-typed `Storage` guarded by `Mutex`. The public type is
/// `Sendable`.
final class StubTransport: LSPTransport, Sendable {
    // MARK: Lifecycle

    init() {
        self.storage = Storage()
    }

    // MARK: Public

    /// Push a payload that the next `readMessage()` will return. The
    /// payload should be the bare JSON body — the transport does not
    /// perform framing here.
    func enqueueRead(_ payload: Data) {
        storage.lock.withLock { state in
            state.pendingReads.append(payload)
        }
    }

    /// Signal EOF so the read loop terminates.
    func close() {
        storage.lock.withLock { state in
            state.closed = true
        }
    }

    /// Decoded JSON envelopes written by the server. Each entry is
    /// the parsed `[String: Any]` payload (best-effort — non-JSON
    /// writes are skipped).
    var writtenEnvelopes: [[String: Any]] {
        storage.lock.withLock { state in
            state.written.compactMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        }
    }

    /// All notifications written by the server, filtered by method.
    func notifications(method: String) -> [[String: Any]] {
        writtenEnvelopes.filter { envelope in
            envelope["method"] as? String == method && envelope["id"] == nil
        }
    }

    /// All responses written by the server, indexed by id.
    func response(forID id: Int) -> [String: Any]? {
        writtenEnvelopes.first { envelope in
            envelope["id"] as? Int == id
        }
    }

    // MARK: LSPTransport

    func readMessage() async throws -> Data? {
        storage.lock.withLock { state in
            if state.pendingReads.isEmpty {
                return state.closed ? nil : Data?.none
            }
            return state.pendingReads.removeFirst()
        }
    }

    func writeMessage(_ data: Data) async throws {
        storage.lock.withLock { state in
            state.written.append(data)
        }
    }

    // MARK: Private

    /// Mutable state for the stub. Held inside a private cage so the
    /// outer type stays `Sendable` without `@unchecked`.
    private final class Storage: @unchecked Sendable {
        // MARK: Lifecycle

        init() {}

        // MARK: Public

        struct State {
            var pendingReads: [Data] = []
            var written: [Data] = []
            var closed = false
        }

        let lock = Mutex<State>(State())
    }

    private let storage: Storage
}
