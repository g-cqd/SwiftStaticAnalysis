//  LSPServer.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Synchronization

// MARK: - LSPTransport

/// Stream-agnostic transport for the LSP message loop. The default
/// transport reads from stdin and writes to stdout, but tests
/// substitute an in-memory implementation to capture publishes.
///
/// Implementations MUST handle the `Content-Length: N\r\n\r\n<json>`
/// framing themselves and present whole-message payloads to the
/// server.
public protocol LSPTransport: Sendable {
    /// Read the next framed message off the wire. Returns `nil` on
    /// EOF/clean shutdown.
    func readMessage() async throws -> Data?

    /// Write a single framed message. The transport is responsible
    /// for prepending the `Content-Length` header and serialising
    /// concurrent writes.
    func writeMessage(_ data: Data) async throws
}

// MARK: - LSPFraming

/// Encoder/decoder for the LSP `Content-Length` framing protocol.
///
/// The pattern mirrors `SourceKitLSPClient` (which speaks the client
/// side of the same wire format). Pulled out into a free-standing
/// type so tests can round-trip without spinning up a process.
public enum LSPFraming {
    /// Encode a JSON payload into a framed LSP message.
    public static func encode(_ payload: Data) -> Data {
        var output = Data()
        let header = "Content-Length: \(payload.count)\r\n\r\n"
        if let headerData = header.data(using: .ascii) {
            output.append(headerData)
        }
        output.append(payload)
        return output
    }

    /// Decode the first framed LSP message from `buffer`. Returns the
    /// payload and the number of bytes consumed (including the
    /// header). Returns `nil` if `buffer` does not yet contain a
    /// complete message.
    public static func decode(_ buffer: Data) -> (payload: Data, consumed: Int)? {
        // Find the `\r\n\r\n` header terminator.
        guard let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            return nil
        }
        let headerRange = buffer.startIndex..<headerEnd.lowerBound
        let headerData = buffer.subdata(in: headerRange)
        guard let headerString = String(data: headerData, encoding: .ascii) else {
            return nil
        }
        var contentLength: Int?
        for line in headerString.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame {
                contentLength = Int(parts[1])
            }
        }
        guard let length = contentLength else {
            return nil
        }
        let payloadStart = headerEnd.upperBound
        let payloadEnd = payloadStart + length
        guard buffer.endIndex >= payloadEnd else {
            return nil
        }
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        let consumed = payloadEnd - buffer.startIndex
        return (payload, consumed)
    }
}

// MARK: - StdioLSPTransport

/// `FileHandle`-backed transport that reads from a stdin handle and
/// writes to a stdout handle. The default initializer uses the
/// process-wide standard handles; tests substitute pipe-backed
/// handles.
///
/// The cage pattern: the public type is `Sendable` and exposes only
/// async functions. Mutable buffering lives inside a private
/// reference-typed `Storage` guarded by `Mutex` (from the
/// `Synchronization` module — `NSLock` is unavailable from async
/// contexts).
public final class StdioLSPTransport: LSPTransport, Sendable {
    // MARK: Lifecycle

    public convenience init() {
        self.init(input: FileHandle.standardInput, output: FileHandle.standardOutput)
    }

    public init(input: FileHandle, output: FileHandle) {
        self.storage = Storage(input: input, output: output)
    }

    // MARK: Public

    public func readMessage() async throws -> Data? {
        await Task.detached(priority: .userInitiated) { [storage] in
            storage.readFramedMessage()
        }.value
    }

    public func writeMessage(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) { [storage] in
            try storage.writeFramedMessage(data)
        }.value
    }

    // MARK: Private

    /// Cage: holds the input/output handles plus a growing read buffer.
    /// The whole class is `private` so the unchecked-Sendable hatch
    /// never escapes module boundaries.
    private final class Storage: @unchecked Sendable {
        // MARK: Lifecycle

        init(input: FileHandle, output: FileHandle) {
            self.input = input
            self.output = output
        }

        // MARK: Public

        /// Read until either a complete framed message arrives or
        /// stdin closes (EOF). Returns the raw JSON payload (header
        /// stripped) or `nil` on EOF.
        func readFramedMessage() -> Data? {
            readLock.withLock { _ in
                while true {
                    if let (payload, consumed) = LSPFraming.decode(readBuffer) {
                        readBuffer.removeSubrange(0..<consumed)
                        return payload
                    }
                    // Need more data. Use a small chunk size; LSP
                    // messages are typically small and we don't want to
                    // block on `availableData` for the entire next
                    // message.
                    let chunk = input.availableData
                    if chunk.isEmpty {
                        return nil  // EOF
                    }
                    readBuffer.append(chunk)
                }
            }
        }

        func writeFramedMessage(_ payload: Data) throws {
            let framed = LSPFraming.encode(payload)
            try writeLock.withLock { _ in
                try output.write(contentsOf: framed)
            }
        }

        // MARK: Private

        private let input: FileHandle
        private let output: FileHandle
        // Mutex storage is `Int` (zero-cost placeholder); the lock
        // protects access to the `readBuffer` and to the output
        // handle. Mutex is the Swift 6 async-safe primitive — NSLock
        // cannot be held across await points.
        private let readLock = Mutex<Int>(0)
        private let writeLock = Mutex<Int>(0)
        private var readBuffer = Data()
    }

    private let storage: Storage
}

// MARK: - LSPServer

/// LSP server core. Owns the document state, runs the message
/// dispatch loop, and pushes diagnostics through the transport.
///
/// ## Lifecycle
///
/// 1. `run()` drives the read loop until the transport returns
///    `nil` (EOF) or `shutdown`/`exit` are received.
/// 2. Each request is dispatched on the actor — there is no
///    parallel dispatch; the actor serialises message handling.
/// 3. Document state is plain `[uri: text]` keyed by URI string.
public actor LSPServer {
    // MARK: Lifecycle

    public init(
        transport: any LSPTransport,
        producer: DiagnosticProducer = DiagnosticProducer(),
        serverInfo: LSPServerInfo = LSPServerInfo(name: "swa-lsp", version: "0.3.0")
    ) {
        self.transport = transport
        self.producer = producer
        self.serverInfo = serverInfo
    }

    // MARK: Public

    /// Drive the read loop until EOF or `exit`. Returns the suggested
    /// process exit code per the LSP spec — `0` for clean shutdown
    /// (received `shutdown` before `exit`), `1` otherwise.
    public func run() async throws -> Int32 {
        while !shouldExit {
            guard let payload = try await transport.readMessage() else {
                // EOF: treat as exit.
                break
            }
            await dispatch(payload: payload)
        }
        return shutdownReceived ? 0 : 1
    }

    /// Public hook for tests: drive a single request/notification
    /// through dispatch without spinning the read loop. The transport
    /// will still receive any outgoing publishDiagnostics messages.
    public func handle(payload: Data) async {
        await dispatch(payload: payload)
    }

    /// Snapshot of currently-open documents. Test seam.
    public var openDocuments: [String: String] { documents }

    // MARK: Private

    private let transport: any LSPTransport
    private let producer: DiagnosticProducer
    private let serverInfo: LSPServerInfo
    private var documents: [String: String] = [:]
    private var documentVersions: [String: Int] = [:]
    private var shutdownReceived = false
    private var shouldExit = false

    /// Dispatch a decoded JSON-RPC payload by method. Unknown
    /// requests get a `methodNotFound` error; unknown notifications
    /// are silently ignored (per JSON-RPC 2.0).
    private func dispatch(payload: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            // Malformed message — best-effort drop.
            return
        }
        let method = object["method"] as? String
        let id = decodeID(object["id"])
        let params = object["params"]

        if let method {
            await handle(method: method, id: id, params: params)
        } else if let id {
            // Result/response back from the client — we never sent a
            // request that needed a response, so drop it.
            _ = id
        }
    }

    private func handle(method: String, id: JSONRPCID?, params: Any?) async {
        switch method {
        case "initialize":
            await handleInitialize(id: id)
        case "initialized":
            // Notification — no-op.
            break
        case "textDocument/didOpen":
            await handleDidOpen(params: params)
        case "textDocument/didChange":
            await handleDidChange(params: params)
        case "textDocument/didClose":
            handleDidClose(params: params)
        case "textDocument/diagnostic":
            await handleDocumentDiagnostic(id: id, params: params)
        case "shutdown":
            handleShutdown(id: id)
            await sendNullResponse(id: id)
        case "exit":
            shouldExit = true
        default:
            if let id {
                await sendError(
                    id: id,
                    error: LSPError(
                        code: LSPError.methodNotFound,
                        message: "Method not supported: \(method)"
                    )
                )
            }
        // Otherwise drop notification per JSON-RPC 2.0.
        }
    }

    private func handleInitialize(id: JSONRPCID?) async {
        let capabilities = LSPServerCapabilities(
            textDocumentSync: LSPTextDocumentSyncOptions(openClose: true, change: .full),
            diagnosticProvider: LSPDiagnosticOptions(
                identifier: "swa",
                interFileDependencies: false,
                workspaceDiagnostics: false
            )
        )
        let result = LSPInitializeResult(capabilities: capabilities, serverInfo: serverInfo)
        await sendResponse(id: id, result: result)
    }

    private func handleDidOpen(params: Any?) async {
        guard let params = decode(params, as: LSPDidOpenParams.self) else { return }
        documents[params.textDocument.uri] = params.textDocument.text
        documentVersions[params.textDocument.uri] = params.textDocument.version
        await publishDiagnostics(
            uri: params.textDocument.uri,
            version: params.textDocument.version,
            text: params.textDocument.text
        )
    }

    private func handleDidChange(params: Any?) async {
        guard let params = decode(params, as: LSPDidChangeParams.self) else { return }
        // Full sync: the last change carries the complete document.
        guard let last = params.contentChanges.last else { return }
        documents[params.textDocument.uri] = last.text
        documentVersions[params.textDocument.uri] = params.textDocument.version
        await publishDiagnostics(
            uri: params.textDocument.uri,
            version: params.textDocument.version,
            text: last.text
        )
    }

    private func handleDidClose(params: Any?) {
        guard let params = decode(params, as: LSPDidCloseParams.self) else { return }
        documents.removeValue(forKey: params.textDocument.uri)
        documentVersions.removeValue(forKey: params.textDocument.uri)
    }

    private func handleDocumentDiagnostic(id: JSONRPCID?, params: Any?) async {
        guard let params = decode(params, as: LSPDocumentDiagnosticParams.self) else {
            if let id {
                await sendError(
                    id: id,
                    error: LSPError(code: LSPError.invalidParams, message: "Invalid diagnostic params")
                )
            }
            return
        }
        let text = documents[params.textDocument.uri] ?? ""
        let diagnostics = await producer.diagnose(uri: params.textDocument.uri, text: text)
        let report = LSPDocumentDiagnosticReport(items: diagnostics)
        await sendResponse(id: id, result: report)
    }

    private func handleShutdown(id: JSONRPCID?) {
        shutdownReceived = true
    }

    /// Run analysis for `uri`+`text` and push a
    /// `textDocument/publishDiagnostics` notification.
    private func publishDiagnostics(uri: String, version: Int?, text: String) async {
        let diagnostics = await producer.diagnose(uri: uri, text: text)
        let params = LSPPublishDiagnosticsParams(uri: uri, version: version, diagnostics: diagnostics)
        await sendNotification(method: "textDocument/publishDiagnostics", params: params)
    }

    // MARK: Wire helpers

    private func decode<T: Decodable>(_ params: Any?, as type: T.Type) -> T? {
        guard let params else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: params)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private func decodeID(_ raw: Any?) -> JSONRPCID? {
        if let value = raw as? Int { return .int(value) }
        if let value = raw as? String { return .string(value) }
        return nil
    }

    private func sendResponse<T: Encodable>(id: JSONRPCID?, result: T) async {
        guard let id else { return }
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": encodeID(id),
        ]
        if let encoded = try? encodeAsJSONObject(result) {
            envelope["result"] = encoded
        } else {
            envelope["result"] = NSNull()
        }
        await write(envelope: envelope)
    }

    /// Send a JSON-RPC response whose `result` is JSON `null`. The
    /// LSP `shutdown` request uses this — the spec requires the
    /// result field be present but null.
    private func sendNullResponse(id: JSONRPCID?) async {
        guard let id else { return }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": encodeID(id),
            "result": NSNull(),
        ]
        await write(envelope: envelope)
    }

    private func sendError(id: JSONRPCID, error: LSPError) async {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": encodeID(id),
            "error": [
                "code": error.code,
                "message": error.message,
            ] as [String: Any],
        ]
        await write(envelope: envelope)
    }

    private func sendNotification<T: Encodable>(method: String, params: T) async {
        var envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let encoded = try? encodeAsJSONObject(params) {
            envelope["params"] = encoded
        }
        await write(envelope: envelope)
    }

    private func encodeID(_ id: JSONRPCID) -> Any {
        switch id {
        case .int(let value): value
        case .string(let value): value
        }
    }

    private func encodeAsJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func write(envelope: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return
        }
        try? await transport.writeMessage(data)
    }
}
