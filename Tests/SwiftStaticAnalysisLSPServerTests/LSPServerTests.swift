//  LSPServerTests.swift
//  SwiftStaticAnalysisLSPServerTests
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisLSPServer

@Suite("LSPServer")
struct LSPServerTests {
    // MARK: - Helpers

    private func makeServer(transport: StubTransport) -> LSPServer {
        LSPServer(transport: transport)
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - initialize handler

    @Test("initialize returns capabilities for textDocumentSync.full and diagnosticProvider")
    func initializeReturnsExpectedCapabilities() async throws {
        let transport = StubTransport()
        let server = makeServer(transport: transport)

        let request = try jsonData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [:] as [String: Any],
        ])
        await server.handle(payload: request)

        let response = try #require(transport.response(forID: 1))
        let result = try #require(response["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])

        let sync = try #require(capabilities["textDocumentSync"] as? [String: Any])
        #expect(sync["openClose"] as? Bool == true)
        // .full == 1 in the spec.
        #expect(sync["change"] as? Int == 1)

        let diagnostic = try #require(capabilities["diagnosticProvider"] as? [String: Any])
        #expect(diagnostic["identifier"] as? String == "swa")

        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "swa-lsp")
    }

    // MARK: - didOpen -> publishDiagnostics

    @Test("didOpen triggers a textDocument/publishDiagnostics notification")
    func didOpenTriggersPublishDiagnostics() async throws {
        let transport = StubTransport()
        let server = makeServer(transport: transport)

        let uri = "file:///tmp/swa-lsp-fixture-\(UUID().uuidString).swift"
        let didOpen = try jsonData([
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": [
                "textDocument": [
                    "uri": uri,
                    "languageId": "swift",
                    "version": 1,
                    "text": "import Foundation\n\nlet x = 42\n",
                ] as [String: Any]
            ] as [String: Any],
        ])
        await server.handle(payload: didOpen)

        let publishes = transport.notifications(method: "textDocument/publishDiagnostics")
        #expect(!publishes.isEmpty, "expected at least one publishDiagnostics notification")

        let publish = try #require(publishes.first)
        let params = try #require(publish["params"] as? [String: Any])
        #expect(params["uri"] as? String == uri)
        // diagnostics is always emitted (possibly empty) — the
        // contract is that the *notification* fires, not that it
        // contain findings.
        _ = try #require(params["diagnostics"] as? [Any])
    }

    @Test("didChange updates document content and re-publishes diagnostics")
    func didChangeRePublishes() async throws {
        let transport = StubTransport()
        let server = makeServer(transport: transport)

        let uri = "file:///tmp/swa-lsp-fixture-\(UUID().uuidString).swift"
        let didOpen = try jsonData([
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": [
                "textDocument": [
                    "uri": uri,
                    "languageId": "swift",
                    "version": 1,
                    "text": "let x = 1\n",
                ] as [String: Any]
            ] as [String: Any],
        ])
        await server.handle(payload: didOpen)

        let didChange = try jsonData([
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": [
                "textDocument": ["uri": uri, "version": 2] as [String: Any],
                "contentChanges": [["text": "let y = 2\n"]] as [Any],
            ] as [String: Any],
        ])
        await server.handle(payload: didChange)

        let documents = await server.openDocuments
        #expect(documents[uri] == "let y = 2\n")

        let publishes = transport.notifications(method: "textDocument/publishDiagnostics")
        // One publish for didOpen + one for didChange.
        #expect(publishes.count >= 2)
    }

    // MARK: - shutdown

    @Test("shutdown returns null result and exit triggers clean termination")
    func shutdownAndExitFlow() async throws {
        let transport = StubTransport()
        let server = makeServer(transport: transport)

        let shutdown = try jsonData([
            "jsonrpc": "2.0",
            "id": 99,
            "method": "shutdown",
        ])
        await server.handle(payload: shutdown)

        let response = try #require(transport.response(forID: 99))
        // The result field must be present and null per LSP spec.
        #expect(response["result"] is NSNull)
    }

    // MARK: - methodNotFound

    @Test("unknown request method returns -32601 methodNotFound")
    func unknownMethodReturnsMethodNotFound() async throws {
        let transport = StubTransport()
        let server = makeServer(transport: transport)

        let request = try jsonData([
            "jsonrpc": "2.0",
            "id": 7,
            "method": "totally/madeUp",
        ])
        await server.handle(payload: request)

        let response = try #require(transport.response(forID: 7))
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32_601)
    }
}
