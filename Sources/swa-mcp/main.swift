/// main.swift
/// swa-mcp - Swift Static Analysis MCP Server
/// MIT License

import ArgumentParser
import Foundation
import MCP
import SwiftStaticAnalysisCore
import SwiftStaticAnalysisMCP

/// MCP server entry point.
///
/// Pre-0.3.0-α this binary parsed its own argv. ArgumentParser handles
/// `--path=…` (attached value), short-option aggregation, and `--`
/// separators correctly; the hand-rolled parser silently mis-handled
/// `--path=/some/path` as a no-op.
@main
struct SWAMCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swa-mcp",
        abstract: "Swift Static Analysis MCP Server",
        discussion: """
            Starts an MCP (Model Context Protocol) server that exposes Swift static
            analysis tools. The server communicates via stdio (stdin/stdout) using
            JSON-RPC 2.0.

            If a codebase path is provided, it becomes the default for all tool calls.
            Tools can also specify a 'codebase_path' parameter to analyze any codebase
            dynamically, regardless of the default.

            If no path is provided at startup, each tool call must include the
            'codebase_path' parameter.

            AVAILABLE TOOLS:
                get_codebase_info    Get information about the codebase
                list_swift_files     List all Swift files in the codebase
                detect_unused_code   Detect unused code
                detect_duplicates    Detect duplicate code
                read_file            Read a file's contents
                search_symbols       Search for symbols by name
                analyze_file         Perform full analysis on a file
            """,
        version: swaVersion
    )

    @Option(name: [.long, .customShort("p")], help: "Path to the default codebase to analyze")
    var path: String?

    @Argument(help: "Path to the default codebase (alternative to --path)")
    var positionalPath: String?

    func run() async throws {
        let raw = path ?? positionalPath
        let absolutePath: String? = raw.map { input in
            PathUtilities.canonicalize(
                input,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        }

        // Log to stderr (stdout is reserved for MCP protocol).
        if let path = absolutePath {
            fputs("swa-mcp: Starting MCP server with default codebase: \(path)\n", stderr)
        } else {
            fputs(
                "swa-mcp: Starting MCP server without default codebase (use codebase_path parameter)\n",
                stderr
            )
        }

        do {
            let server = try SWAMCPServer(codebasePath: absolutePath)
            let transport = StdioTransport()

            fputs("swa-mcp: Server initialized, waiting for client connection...\n", stderr)
            try await server.start(transport: transport)

            // Park the main task indefinitely; let Task cancellation
            // propagate (SIGINT/SIGTERM via async signal handlers). The
            // previous `withCheckedContinuation` form never resumed and so
            // could not be cancelled from within Swift Concurrency.
            try await Task.sleep(for: .seconds(.greatestFiniteMagnitude))
        } catch is CancellationError {
            fputs("swa-mcp: Shutting down...\n", stderr)
        } catch {
            fputs("swa-mcp: Error: \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }
    }
}
