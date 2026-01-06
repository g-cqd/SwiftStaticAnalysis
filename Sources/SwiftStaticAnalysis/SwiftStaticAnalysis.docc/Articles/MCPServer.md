# MCP Server Integration

Integrate Swift Static Analysis with AI assistants using the Model Context Protocol.

## Overview

SwiftStaticAnalysis includes a Model Context Protocol (MCP) server that allows AI assistants like Claude to analyze Swift codebases. The MCP server exposes all analysis tools through a standardized protocol, enabling natural language interaction with your codebase.

## Running the MCP Server

### Command Line

Build and run the MCP server with a default codebase:

```bash
swift build -c release
.build/release/swa-mcp /path/to/your/project
```

Or run without a default codebase (clients must specify `codebase_path` for each tool call):

```bash
.build/release/swa-mcp
```

### Claude Desktop Configuration

To use with Claude Desktop, add the following to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "swa": {
      "command": "/path/to/swa-mcp",
      "args": ["/path/to/your/project"]
    }
  }
}
```

## Available Tools

The MCP server exposes the following tools:

### get_codebase_info

Get information about the codebase including file count, lines of code, and total size.

**Parameters:**
- `codebase_path` (optional): Path to analyze. Uses default if not specified.

**Example Response:**
```json
{
  "root_path": "/path/to/project",
  "swift_file_count": 42,
  "total_lines": 15000,
  "total_size": "1.2 MB"
}
```

### list_swift_files

List all Swift files in the codebase with optional filtering.

**Parameters:**
- `codebase_path` (optional): Path to analyze
- `exclude_patterns` (optional): Glob patterns to exclude (e.g., `**/Tests/**`)
- `limit` (optional): Maximum number of files to return

### detect_unused_code

Detect unused code including functions, types, variables, and imports.

**Parameters:**
- `codebase_path` (optional): Path to analyze
- `mode`: Detection mode - `simple` or `reachability`
- `min_confidence`: Minimum confidence level - `low`, `medium`, or `high`
- `include_public`: Whether to include public API (default: false)
- `treat_public_as_root`: Treat public API as entry points
- `treat_objc_as_root`: Treat @objc declarations as entry points
- `treat_tests_as_root`: Treat test methods as entry points
- `treat_swiftui_views_as_root`: Treat SwiftUI Views as entry points
- `exclude_imports`: Exclude import statements
- `ignore_swiftui_property_wrappers`: Ignore SwiftUI property wrappers
- `ignore_preview_providers`: Ignore PreviewProvider implementations
- `ignore_view_body`: Ignore View body properties
- `index_store_path`: Path to IndexStore for enhanced accuracy
- `exclude_paths`: Glob patterns to exclude
- `paths`: Specific paths to analyze

### detect_duplicates

Find duplicate code patterns in the codebase.

**Parameters:**
- `codebase_path` (optional): Path to analyze
- `clone_types`: Types of clones to detect - `exact`, `near`, `semantic`
- `min_tokens`: Minimum token count (default: 50)
- `min_similarity`: Minimum similarity 0.0-1.0 (default: 0.8)
- `algorithm`: Detection algorithm - `rollingHash`, `suffixArray`, `minHashLSH`
- `exclude_paths`: Glob patterns to exclude
- `paths`: Specific paths to analyze

### read_file

Read the contents of a Swift file within the codebase.

**Parameters:**
- `codebase_path` (optional): Path to codebase
- `path` (required): Path to the file
- `start_line` (optional): Starting line number (1-indexed)
- `end_line` (optional): Ending line number (1-indexed)

### search_symbols

Search for symbols with optional context extraction.

**Parameters:**
- `codebase_path` (optional): Path to analyze
- `query` (required): Symbol name or pattern to search
- `kind`: Filter by symbol kind - `function`, `method`, `class`, `struct`, `enum`, `protocol`, `variable`, `constant`, `typealias`
- `access_level`: Filter by minimum access level
- `definition_only`: Only return definitions (default: true)
- `use_regex`: Treat query as regex pattern (default: false)
- `limit`: Maximum results to return
- `context_lines`: Lines of context before and after symbol
- `context_before`: Lines of context before symbol
- `context_after`: Lines of context after symbol
- `context_scope`: Include containing scope information
- `context_signature`: Include complete signature
- `context_body`: Include declaration body
- `context_documentation`: Include documentation comments
- `context_all`: Include all context information

### analyze_file

Perform full static analysis on a specific Swift file.

**Parameters:**
- `codebase_path` (optional): Path to codebase
- `path` (required): Path to the Swift file
- `include_declarations`: Include declaration listing (default: true)
- `include_references`: Include reference listing (default: true)
- `max_references`: Maximum references to return (default: 100)
- `declaration_kinds`: Filter declarations by kinds
- `include_imports`: Include import statements (default: true)
- `include_scopes`: Include scope hierarchy information (default: false)

## Programmatic Usage

You can also use the MCP server programmatically:

```swift
import SwiftStaticAnalysisMCP
import MCP

// Create server with default codebase
let server = try SWAMCPServer(codebasePath: "/path/to/codebase")

// Or create without default (dynamic paths)
let dynamicServer = try SWAMCPServer(codebasePath: nil)

// Start with stdio transport
let transport = StdioTransport()
try await server.start(transport: transport)
```

## Security

The MCP server implements sandboxed access to ensure secure operation:

- All file operations are restricted to the configured codebase root
- Path traversal attempts (e.g., `../../../etc/passwd`) are rejected
- Absolute paths outside the sandbox are blocked
- Only Swift files within the codebase can be read

## See Also

- <doc:CLIReference>
- <doc:SymbolLookup>
- <doc:CIIntegration>
