# ``SwiftStaticAnalysis``

A high-performance Swift static analysis framework for code duplication detection, unused code elimination, symbol lookup, and AI assistant integration.

## Overview

SwiftStaticAnalysis provides comprehensive tools for analyzing Swift codebases to find duplicated code patterns, unused declarations, and look up symbols. The framework is designed for performance with memory-mapped I/O, arena allocation, and parallel processing enabled by default.

## Modules

The framework consists of five main modules:

### SwiftStaticAnalysisCore

Core infrastructure including:
- Declaration and reference models
- SwiftSyntax-based parsing with caching
- Visitor patterns for AST traversal
- Memory-efficient token storage

### DuplicationDetector

Clone detection with multiple algorithms:
- **Exact Clones (Type-1)**: Identical code via Suffix Array (SA-IS)
- **Near Clones (Type-2)**: Renamed variables via MinHash + LSH
- **Semantic Clones (Type-3/4)**: Functionally equivalent via AST fingerprinting
- **Parallel MinHash/LSH**: Parallel signature, candidate, and verification pipeline (enabled by default)
- **Streaming Pipelines**: Candidate pair and verification streaming for memory-bounded analysis

### UnusedCodeDetector

Unused code detection with configurable modes:
- **Simple Mode**: Fast syntax-based detection
- **Reachability Mode**: Graph-based dead code analysis with parallel BFS (enabled by default)
- **IndexStore Mode**: Cross-module accuracy using compiler index
- **Streaming Edge Extraction**: Incremental graph edge emission for large codebases

### SymbolLookup

Symbol resolution and lookup capabilities:
- **Query Patterns**: Simple names, qualified names, selectors, USRs, regex
- **Dual Resolution**: IndexStore for speed, Syntax for accuracy
- **Usage Tracking**: Find all references to a symbol
- **Context Extraction**: Surrounding code, documentation, signatures, and scope information

### SwiftStaticAnalysisMCP

Model Context Protocol (MCP) server for AI assistant integration:
- **MCP Server**: Expose analysis tools to AI assistants like Claude
- **Sandboxed Access**: Secure codebase access with path validation
- **Rich Tool Set**: Symbol search, unused code detection, duplicate detection, and file analysis

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:CLIReference>

### Detection

- <doc:CloneDetection>
- <doc:UnusedCodeDetection>
- <doc:SymbolLookup>

### Integration

- <doc:MCPServer>
- <doc:CIIntegration>

### Configuration

- <doc:IgnoreDirectives>
- <doc:PerformanceOptimization>

## API Reference

The SwiftStaticAnalysis umbrella module re-exports all sub-modules. Import `SwiftStaticAnalysis` to access:

| Module | Key Types |
|--------|-----------|
| SwiftStaticAnalysisCore | `Declaration`, `Reference`, `SourceLocation`, `AnalysisResult` |
| DuplicationDetector | `DuplicationDetector`, `CloneType`, `Clone`, `CloneGroup` |
| UnusedCodeDetector | `UnusedCodeDetector`, `UnusedCode`, `Confidence` |
| SymbolLookup | `SymbolFinder`, `SymbolQuery`, `SymbolMatch`, `SymbolContextExtractor` |
| SwiftStaticAnalysisMCP | `SWAMCPServer`, `CodebaseContext` |

See the individual guides for detailed usage of each module.
