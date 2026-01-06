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

@_exported import MCP
