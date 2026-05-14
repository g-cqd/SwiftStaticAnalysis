# ``SwiftStaticAnalysis``

A high-performance Swift static analysis framework for code duplication detection, unused code elimination, symbol lookup, and AI assistant integration.

## Overview

SwiftStaticAnalysis provides tools for analysing Swift codebases to find duplicated code patterns, unused declarations, and look up symbols. The framework is designed for performance: memory-mapped I/O is wired through every parser hot path, the reachability analyser projects USR-keyed adjacency lists onto a bit-packed `DenseGraph`, MinHash uses real `SIMD4<UInt64>` with Mersenne-prime reduction, and bounded LRU caches keep long-running MCP sessions within budget.

## Choosing an umbrella module

`SwiftStaticAnalysis` re-exports the analyser libraries (`SwiftStaticAnalysisCore`, `DuplicationDetector`, `UnusedCodeDetector`, `SymbolLookup`). It does **not** depend on `modelcontextprotocol/swift-sdk`, so library consumers that don't embed the MCP server pay no transitive dependency cost.

`SwiftStaticAnalysisAll` adds `SwiftStaticAnalysisMCP` on top. Use it when you embed `SWAMCPServer` in your own host process.

```swift
// Analyser-only:
.product(name: "SwiftStaticAnalysis", package: "SwiftStaticAnalysis")

// Analyser + MCP server:
.product(name: "SwiftStaticAnalysisAll", package: "SwiftStaticAnalysis")
```

## Modules

The framework consists of five main modules:

### SwiftStaticAnalysisCore

Core infrastructure including:
- Declaration and reference models
- SwiftSyntax-based parsing with bounded LRU caching
- Visitor patterns for AST traversal
- Memory-mapped I/O (`MemoryMappedFile`, `SourceFileReader`)
- Bit-packed reachability primitives (`Bitmap`, `AtomicBitmap`)
- Bump-allocator scratch arena (`Arena`)
- Process executor with environment scrubbing (`ProcessExecutor`)

### DuplicationDetector

Clone detection with multiple algorithms:
- **Exact Clones (Type-1)**: Identical code via Suffix Array (SA-IS) with bit-packed type vector
- **Near Clones (Type-2)**: Renamed variables via real-SIMD MinHash + LSH (Mersenne-prime modulus, SplitMix64 coefficients)
- **Semantic Clones (Type-3/4)**: Functionally equivalent via AST fingerprinting
- **Parallel MinHash/LSH**: Parallel signature, candidate, and verification pipeline
- **Streaming pipelines**: `streamResults` (buffered) and `streamResultsBackpressured` (`AsyncChannel`-backed) variants

### UnusedCodeDetector

Unused code detection with configurable modes:
- **Simple Mode**: Fast syntax-based detection
- **Reachability Mode**: Graph-based dead code analysis. BFS runs over `DenseGraph` with `Bitmap` visited tracking; auto-selects direction-optimising parallel BFS for large graphs
- **IndexStore Mode**: Cross-module accuracy using compiler index, with a single-sweep `allOccurrencesByUSR(in:)` query to avoid N+1 round trips

### SymbolLookup

Symbol resolution and lookup capabilities:
- **Query Patterns**: Simple names, qualified names, selectors, USRs, regex
- **Dual Resolution**: IndexStore for speed, Syntax for accuracy
- **Usage Tracking**: Find all references to a symbol
- **Context Extraction**: Surrounding code, documentation, signatures, and scope information (mmap-backed reads)

### SwiftStaticAnalysisMCP

Model Context Protocol (MCP) server for AI assistant integration:
- **MCP Server**: Expose analysis tools to AI assistants like Claude
- **Sandboxed Access**: Canonical-path + symlink-resolved validation, separator-aware prefix check
- **Hardened Tools**: `read_file` and `ReadResource` share a single regular-file/extension/size guard; `search_symbols` enforces a ReDoS budget and antipattern prefilter

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:CLIReference>
- <doc:Architecture>

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

### Operations

- <doc:Performance>
- <doc:Security>

## API Reference

The `SwiftStaticAnalysis` umbrella module re-exports the analyser libraries. Import `SwiftStaticAnalysis` to access:

| Module | Key Types |
|--------|-----------|
| SwiftStaticAnalysisCore | `Declaration`, `Reference`, `SourceLocation`, `AnalysisResult`, `MemoryMappedFile`, `SourceFileReader`, `Bitmap`, `AtomicBitmap`, `ProcessExecutor`, `BackpressuredChannelStream` |
| DuplicationDetector | `DuplicationDetector`, `CloneType`, `Clone`, `CloneGroup`, `StreamingVerifier` |
| UnusedCodeDetector | `UnusedCodeDetector`, `UnusedCode`, `Confidence`, `ReachabilityGraph` |
| SymbolLookup | `SymbolFinder`, `SymbolQuery`, `SymbolMatch`, `SymbolContextExtractor` |

For the MCP server, import `SwiftStaticAnalysisAll` (which transitively exports `SWAMCPServer`, `CodebaseContext`).

See the individual guides for detailed usage of each module.
