/// main.swift
/// swa-mcp - Swift Static Analysis MCP Server
/// MIT License

import Foundation
import MCP
import SwiftStaticAnalysisCore
import SwiftStaticAnalysisMCP

/// Parse command line arguments and run the MCP server.
@main
struct SWAMCPCommand {
    static func main() async {
        // Parse arguments
        let arguments = CommandLine.arguments

        // Help message
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }

        // Version
        if arguments.contains("--version") || arguments.contains("-v") {
            print("swa-mcp 0.2.0")
            return
        }

        // Get optional codebase path
        let codebasePath: String?

        if let pathIndex = arguments.firstIndex(of: "--path"),
            pathIndex + 1 < arguments.count
        {
            codebasePath = arguments[pathIndex + 1]
        } else if let pathIndex = arguments.firstIndex(of: "-p"),
            pathIndex + 1 < arguments.count
        {
            codebasePath = arguments[pathIndex + 1]
        } else if arguments.count > 1, !arguments[1].hasPrefix("-") {
            // First non-flag argument is the path
            codebasePath = arguments[1]
        } else {
            // No default path - tools must specify codebase_path
            codebasePath = nil
        }

        // Resolve path if provided. PathUtilities handles ~ expansion without
        // the NSString bridge and produces a canonical absolute path so the
        // CodebaseContext sandbox check has stable input.
        let absolutePath: String? =
            codebasePath.map { path in
                PathUtilities.canonicalize(
                    path,
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                )
            }

        // Log to stderr (stdout is reserved for MCP protocol)
        if let path = absolutePath {
            fputs("swa-mcp: Starting MCP server with default codebase: \(path)\n", stderr)
        } else {
            fputs("swa-mcp: Starting MCP server without default codebase (use codebase_path parameter)\n", stderr)
        }

        do {
            // Create and start the server
            let server = try SWAMCPServer(codebasePath: absolutePath)

            // Use stdio transport
            let transport = StdioTransport()

            fputs("swa-mcp: Server initialized, waiting for client connection...\n", stderr)

            try await server.start(transport: transport)

            // Park the main task indefinitely while letting Task cancellation
            // propagate (SIGINT/SIGTERM via async signal handlers). The
            // previous `withCheckedContinuation` form never resumed and so
            // could not be cancelled from within Swift Concurrency.
            try await Task.sleep(for: .seconds(.greatestFiniteMagnitude))
        } catch is CancellationError {
            await SWAMCPCommand.shutdown()
        } catch {
            fputs("swa-mcp: Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// Graceful shutdown hook. No-op today; the MCP server's stdio transport
    /// will be cleaned up by deinit when the process exits.
    private static func shutdown() async {
        fputs("swa-mcp: Shutting down...\n", stderr)
    }

    static func printUsage() {
        let usage = """
            swa-mcp - Swift Static Analysis MCP Server

            USAGE:
                swa-mcp [OPTIONS] [CODEBASE_PATH]

            ARGUMENTS:
                CODEBASE_PATH    Path to the default codebase to analyze (optional)

            OPTIONS:
                -p, --path PATH  Path to the default codebase to analyze
                -h, --help       Print this help message
                -v, --version    Print version information

            DESCRIPTION:
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

            EXAMPLES:
                # Start server without default codebase (dynamic mode)
                swa-mcp

                # Start server with a default codebase
                swa-mcp /path/to/project

                # Use with Claude Code MCP configuration (dynamic mode)
                # Add to ~/.claude/mcp_servers.json:
                {
                    "swa": {
                        "command": "swa-mcp"
                    }
                }

                # Use with Claude Code MCP configuration (fixed codebase)
                # Add to ~/.claude/mcp_servers.json:
                {
                    "swa": {
                        "command": "swa-mcp",
                        "args": ["/path/to/project"]
                    }
                }

            """
        print(usage)
    }
}
