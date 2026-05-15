/// SwiftStaticAnalysisMCP.swift
/// SwiftStaticAnalysisMCP
/// MIT License
///
/// This module provides an MCP (Model Context Protocol) server for Swift Static Analysis.
///
/// ## Overview
///
/// The SwiftStaticAnalysisMCP package exposes SWA analysis capabilities through the
/// Model Context Protocol, allowing AI assistants and other MCP clients to analyze
/// Swift codebases.
///
/// ## Key Types
///
/// - ``SWAMCPServer``: The main MCP server that handles tool calls.
/// - ``CodebaseContext``: Manages the sandboxed codebase path.
///
/// ## Usage
///
/// ```swift
/// import SwiftStaticAnalysisMCP
/// import MCP
///
/// let server = try SWAMCPServer(codebasePath: "/path/to/codebase")
/// let transport = StdioTransport()
/// try await server.start(transport: transport)
/// ```
///
/// ## Available Tools
///
/// The server exposes the following MCP tools:
///
/// - `get_codebase_info`: Get information about the codebase
/// - `list_swift_files`: List all Swift files
/// - `detect_unused_code`: Detect unused code
/// - `detect_duplicates`: Detect duplicate code
/// - `read_file`: Read file contents
/// - `search_symbols`: Search for symbols
/// - `analyze_file`: Full file analysis

// MCP types that genuinely appear in the public signatures of this module:
// only `Transport` (the parameter of `SWAMCPServer.start(transport:)`). The
// rest of the MCP swift-sdk surface (`Server`, `CallTool.Result`,
// `Resource`, …) is implementation detail of the handlers. Consumers that
// build or test the server should `import MCP` themselves.
import MCP

/// Re-export the one MCP type that appears in `SWAMCPServer`'s public
/// interface. A full `@_exported import MCP` would silently couple
/// every consumer to whatever version of `modelcontextprotocol/swift-sdk`
/// we track; narrowing the re-export keeps the public surface honest.
public typealias Transport = MCP.Transport
