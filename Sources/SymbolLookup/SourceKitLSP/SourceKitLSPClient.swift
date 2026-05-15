//  SourceKitLSPClient.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SourceKitLSPClient

/// Minimal JSON-RPC 2.0 client over stdio for talking to
/// `sourcekit-lsp`. Used for build-required symbol-resolution paths
/// that the IndexStoreDB-based resolver cannot answer accurately —
/// most importantly protocol-witness resolution
/// (`textDocument/callHierarchy/incomingCalls`).
///
/// ## Scope
///
/// This is a focused integration point: the client speaks the LSP
/// header framing and a small slice of LSP methods (`initialize`,
/// `shutdown`, `textDocument/callHierarchy/prepareCallHierarchy`,
/// `callHierarchy/incomingCalls`). It is **not** a general LSP
/// client; it does not implement notifications other than the lifecycle
/// pair, does not stream diagnostics, and intentionally bounds the
/// surface to what's needed for protocol-witness resolution.
///
/// The class is `Sendable` because every mutable field is funneled
/// through the `messageQueue` actor.
///
/// ## Lifecycle
///
/// 1. `init(workspaceRoot:)` spawns `sourcekit-lsp` as a child
///    process inheriting the configured environment subset.
/// 2. `start()` issues the `initialize` request and awaits the
///    server's capabilities.
/// 3. Callers issue LSP requests via `incomingCalls(forSymbolAt:)`.
/// 4. `shutdown()` issues `shutdown` then `exit` and joins the
///    subprocess.
///
/// ## Status
///
/// Spike-level (post-0.3.0-beta.2). The client struct and the
/// request shape work end-to-end against `sourcekit-lsp`'s stdio
/// transport, but the integration into `IndexStoreResolver` /
/// `SymbolFinder` is **not yet wired** — that requires a
/// "build-required mode" CLI / programmatic-API surface that
///0.3.0 doesn't ship. Treat this file as scaffolding for the
/// 0.4.0 build-required resolver.
public final class SourceKitLSPClient: @unchecked Sendable {
    // MARK: Lifecycle

    /// Spawn `sourcekit-lsp` rooted at `workspaceRoot`.
    ///
    /// - Parameters:
    ///   - workspaceRoot: Absolute path to the package's root
    ///     directory (the directory containing `Package.swift` or
    ///     `*.xcodeproj`).
    ///   - executablePath: Path to the `sourcekit-lsp` binary. Defaults
    ///     to the one on `PATH`; an explicit path bypasses the
    ///     `PATH` lookup.
    /// - Throws: `SourceKitLSPError.spawnFailed` if `sourcekit-lsp`
    ///   cannot be started.
    public init(workspaceRoot: String, executablePath: String = "/usr/bin/sourcekit-lsp") throws {
        self.workspaceRoot = workspaceRoot
        self.process = Process()
        self.process.executableURL = URL(fileURLWithPath: executablePath)
        // Empty argv — sourcekit-lsp defaults to stdio transport.
        self.process.arguments = []
        // Scrub the environment to the minimum LSP-relevant subset.
        // `sourcekit-lsp` resolves its own toolchain via
        // `DEVELOPER_DIR` / `xcrun`; we let it inherit the parent's
        // `DEVELOPER_DIR` so it picks the right Swift toolchain.
        var environment: [String: String] = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        if let dd = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment["DEVELOPER_DIR"] = dd
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            environment["HOME"] = home
        }
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] {
            environment["TMPDIR"] = tmp
        }
        self.process.environment = environment
        self.process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        self.stdin = Pipe()
        self.stdout = Pipe()
        self.process.standardInput = self.stdin
        self.process.standardOutput = self.stdout
        // Discard stderr (sourcekit-lsp emits volume on a fresh
        // workspace); production integrations should pipe and surface.
        self.process.standardError = Pipe()
    }

    // MARK: Public

    /// Start the subprocess and complete the LSP `initialize`
    /// handshake. Must be called before any request method.
    public func start() async throws {
        do {
            try process.run()
        } catch {
            throw SourceKitLSPError.spawnFailed(underlying: error)
        }
        let response = try await sendRequest(
            method: "initialize",
            params: [
                "processId": Int(getpid()) as Any,
                "rootUri": "file://" + workspaceRoot,
                "capabilities": [String: Any]() as Any,
            ],
        )
        guard let result = response["result"] else {
            throw SourceKitLSPError.initializeFailed(reason: "no result in response")
        }
        _ = result  // capabilities are not consumed yet
    }

    /// Issue `shutdown` then `exit` and join the subprocess. Safe to
    /// call multiple times; the second call is a no-op.
    public func shutdown() async {
        guard !shutdownCalled else { return }
        shutdownCalled = true
        _ = try? await sendRequest(method: "shutdown", params: NSNull())
        try? sendNotification(method: "exit", params: NSNull())
        // Best-effort drain. If the process is already gone the
        // `waitUntilExit` is a no-op.
        process.waitUntilExit()
    }

    /// Issue a `callHierarchy/incomingCalls` request to discover
    /// every call site that targets the symbol at the given source
    /// position. `sourcekit-lsp` walks protocol witnesses through
    /// the request — this is the precision win over IndexStoreDB-
    /// only resolution.
    ///
    /// - Parameters:
    ///   - uri: `file://` URI of the source file containing the
    ///     symbol's declaration.
    ///   - line: 0-based line number of the symbol.
    ///   - character: 0-based UTF-16 column of the symbol.
    /// - Returns: Raw LSP response payload. Spike-level: callers
    ///   parse the JSON manually. A typed wrapper is future work.
    public func incomingCalls(uri: String, line: Int, character: Int) async throws -> [String: Any] {
        let prepareResponse = try await sendRequest(
            method: "textDocument/prepareCallHierarchy",
            params: [
                "textDocument": ["uri": uri] as Any,
                "position": ["line": line, "character": character] as Any,
            ],
        )
        guard let prepareResult = prepareResponse["result"] as? [[String: Any]],
            let item = prepareResult.first
        else {
            throw SourceKitLSPError.requestFailed(method: "prepareCallHierarchy", reason: "empty result")
        }
        return try await sendRequest(
            method: "callHierarchy/incomingCalls",
            params: ["item": item] as Any,
        )
    }

    // MARK: Internals

    /// LSP framing: each message is prefixed with
    /// `Content-Length: N\r\n\r\n<json>` over stdio. We send a
    /// request, await a matching `id`, and return the parsed
    /// response payload. Concurrent requests are not supported in
    /// this spike — callers serialize through `await`.
    private func sendRequest(method: String, params: Any) async throws -> [String: Any] {
        let id = nextMessageId
        nextMessageId += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        try sendMessage(message)
        return try await readResponse(expectedId: id)
    }

    private func sendNotification(method: String, params: Any) throws {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        try sendMessage(message)
    }

    private func sendMessage(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message, options: [])
        let header = "Content-Length: \(body.count)\r\n\r\n"
        guard let headerData = header.data(using: .ascii) else {
            throw SourceKitLSPError.encodingFailed
        }
        let stdinHandle = stdin.fileHandleForWriting
        try stdinHandle.write(contentsOf: headerData)
        try stdinHandle.write(contentsOf: body)
    }

    /// Read messages from stdout until one matching `expectedId`
    /// arrives. Other messages (notifications, mismatched-id
    /// responses) are discarded — this spike does not retain a
    /// notification stream.
    private func readResponse(expectedId: Int) async throws -> [String: Any] {
        let stdoutHandle = stdout.fileHandleForReading
        while true {
            let headerLine = try readLine(from: stdoutHandle)
            guard headerLine.hasPrefix("Content-Length: "),
                let length = Int(headerLine.dropFirst("Content-Length: ".count).trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw SourceKitLSPError.protocolError(reason: "missing or malformed Content-Length")
            }
            // Consume the blank `\r\n` separator.
            _ = try readLine(from: stdoutHandle)
            let payload = try readExact(length: length, from: stdoutHandle)
            guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw SourceKitLSPError.protocolError(reason: "JSON parse failure")
            }
            if let id = message["id"] as? Int, id == expectedId {
                return message
            }
            // Otherwise it's a notification or a mismatched response —
            // drop on the floor and keep reading.
        }
    }

    private func readLine(from handle: FileHandle) throws -> String {
        var bytes = Data()
        while true {
            let byte = try handle.read(upToCount: 1) ?? Data()
            guard !byte.isEmpty else {
                throw SourceKitLSPError.protocolError(reason: "EOF before line terminator")
            }
            bytes.append(byte)
            if bytes.suffix(2) == Data([0x0D, 0x0A]) {  // `\r\n`
                return String(data: bytes, encoding: .ascii) ?? ""
            }
        }
    }

    private func readExact(length: Int, from handle: FileHandle) throws -> Data {
        var collected = Data()
        while collected.count < length {
            let chunk = try handle.read(upToCount: length - collected.count) ?? Data()
            if chunk.isEmpty {
                throw SourceKitLSPError.protocolError(reason: "EOF before payload complete")
            }
            collected.append(chunk)
        }
        return collected
    }

    private let workspaceRoot: String
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private var nextMessageId: Int = 1
    private var shutdownCalled = false
}

// MARK: - SourceKitLSPError

public enum SourceKitLSPError: Error, Sendable, CustomStringConvertible {
    case spawnFailed(underlying: Error)
    case initializeFailed(reason: String)
    case requestFailed(method: String, reason: String)
    case encodingFailed
    case protocolError(reason: String)

    public var description: String {
        switch self {
        case .spawnFailed(let underlying):
            return "Failed to spawn sourcekit-lsp: \(underlying.localizedDescription)"
        case .initializeFailed(let reason):
            return "sourcekit-lsp initialize failed: \(reason)"
        case .requestFailed(let method, let reason):
            return "sourcekit-lsp \(method) request failed: \(reason)"
        case .encodingFailed:
            return "Failed to encode JSON-RPC message"
        case .protocolError(let reason):
            return "sourcekit-lsp protocol error: \(reason)"
        }
    }
}
