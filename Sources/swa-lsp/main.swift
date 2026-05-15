//  main.swift
//  swa-lsp — Swift Static Analysis LSP Server
//  MIT License

import ArgumentParser
import Foundation
import SwiftStaticAnalysisLSPServer

// MARK: - SWALSPCommand

/// `swa-lsp` is a Language Server Protocol server that surfaces
/// SwiftStaticAnalysis duplication and unused-code detection results
/// as editor diagnostics. The server speaks JSON-RPC over stdio using
/// the LSP `Content-Length` framing.
///
/// Typical wiring in an editor's LSP client config:
///
/// ```jsonc
/// {
///   "command": "swa-lsp",
///   "languages": ["swift"]
/// }
/// ```
@main
struct SWALSPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swa-lsp",
        abstract: "Swift Static Analysis LSP server (diagnostics for Swift files).",
        discussion: """
            Reads LSP JSON-RPC messages from stdin and writes responses to
            stdout. The server advertises full text-document sync and a
            pull-diagnostic provider; it also pushes
            `textDocument/publishDiagnostics` on open/change.

            Logs and human-readable status are written to stderr so they
            do not interleave with the LSP framing.
            """
    )

    func run() async throws {
        FileHandle.standardError.write(
            Data("swa-lsp: starting LSP server on stdio\n".utf8)
        )
        let transport = StdioLSPTransport()
        let server = LSPServer(transport: transport)
        let exitCode = try await server.run()
        FileHandle.standardError.write(
            Data("swa-lsp: server exiting with code \(exitCode)\n".utf8)
        )
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }
}
