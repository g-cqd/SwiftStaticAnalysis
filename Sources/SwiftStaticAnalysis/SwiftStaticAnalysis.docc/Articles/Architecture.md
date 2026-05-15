# Architecture

A map of the package's modules, their dependency graph, and the
abstraction boundaries each layer maintains.

## Overview

SwiftStaticAnalysis is split across small, focused modules so that
consumers can opt into only what they need.

```
                ┌─────────────────────────────────────┐
                │   SwiftStaticAnalysisAll  (umbrella) │
                │   • re-exports SwiftStaticAnalysis   │
                │   • re-exports SwiftStaticAnalysisMCP│
                └────────────────┬────────────────────┘
                                 │
                ┌────────────────▼───────────────────┐
                │ SwiftStaticAnalysis  (umbrella, no MCP) │
                │ • re-exports the analyser libraries │
                └─┬──────────┬──────────┬────────────┘
                  │          │          │
   ┌──────────────▼─┐  ┌─────▼──────┐  ┌▼────────────┐
   │ DuplicationDetector │  │ UnusedCodeDetector │  │ SymbolLookup │
   │ • exact / near /   │  │ • simple / reach. /│  │ • Symbol-    │
   │   semantic clones  │  │   IndexStore       │  │   Finder    │
   │ • SuffixArray, SA-IS│  │ • DenseGraph BFS   │  │ • Query-    │
   │ • real-SIMD MinHash │  │ • IndexStoreDB     │  │   Parser    │
   └──────────────┬──────┘  └─────┬──────┬─────┘  └┬─────────────┘
                  │               │      │         │
                  │               │      └─────────┘   (UnusedCodeDetector
                  │               │                     supplies IndexStore
                  │               │                     types to SymbolLookup)
                  │               │
              ┌───▼───────────────▼────────────────┐
              │     SwiftStaticAnalysisCore         │
              │  Models  • Parsing • Memory • IO    │
              │  AtomicBitmap • Arena • IndexStore  │
              │  Concurrency • DenseGraph utilities │
              └─────────────────────────────────────┘
```

## Two umbrellas

`SwiftStaticAnalysis` re-exports the analyser libraries only. Importing
it does **not** pull in `modelcontextprotocol/swift-sdk` — useful for
library consumers that don't embed the MCP server.

`SwiftStaticAnalysisAll` extends `SwiftStaticAnalysis` with
`SwiftStaticAnalysisMCP`. Use this when you embed `SWAMCPServer` in
your own host process.

## Module boundaries

- **SwiftStaticAnalysisCore** has no dependency on the detector modules.
  It owns models (`Declaration`, `Reference`, `SourceLocation`), parsing
  (`SwiftFileParser`), memory (`MemoryMappedFile`, `SourceFileReader`,
  `Arena`), the IndexStore reader / fallback layer, concurrency
  primitives (`AtomicBitmap`, `BackpressuredChannelStream`,
  `TaskBackedAsyncStream`), and utilities (`FNV1a`, `PathUtilities`,
  `RegexCache`).
- **DuplicationDetector** depends on Core only. Its SuffixArray /
  MinHash / Parallel internals are all `internal` or `package`.
- **UnusedCodeDetector** depends on Core. Reachability and IndexStore
  analyzer helpers are mostly `internal` or `package`.
- **SymbolLookup** depends on Core. Its `IndexStoreResolver` consumes
  the `IndexStoreReader` and `IndexedOccurrence` types that Core owns.
- **SwiftStaticAnalysisMCP** depends on Core + DuplicationDetector +
  UnusedCodeDetector + SymbolLookup + `swift-sdk`.

The `IndexStoreReader` / `IndexStoreFallback` types live in Core. No
detector module imports another detector module.

## Layering rules

| Layer | Imports allowed |
|---|---|
| Core | Foundation, SwiftParser, SwiftSyntax, swift-collections, swift-algorithms, swift-async-algorithms, Synchronization, IndexStoreDB, SystemPackage |
| DuplicationDetector | + Core |
| UnusedCodeDetector | + Core |
| SymbolLookup | + Core |
| SwiftStaticAnalysisOutput | + Core, DuplicationDetector, UnusedCodeDetector (formatting only) |
| SwiftStaticAnalysisMCP | + Core, all analysers, MCP |
| SwiftStaticAnalysis | re-exports the analyser layers |
| SwiftStaticAnalysisAll | re-exports the analyser layers + MCP |

CI rejects PRs that introduce a cycle or a layer violation; see the
`ModuleStructureTests` suite under `Tests/SwiftStaticAnalysisTests/`.

## Executables and plugins

- `swa` — the CLI tool. Built from `Sources/swa`, depends on Core +
  analysers + Output. Plumbing only; no analysis logic lives here.
- `swa-mcp` — the MCP server entry point. Wraps `SWAMCPServer` with
  `StdioTransport`.
- `swa-bench` — the perf benchmark runner. Imports the analyser layers
  and emits JSON reports.
- `StaticAnalysisBuildPlugin`, `StaticAnalysisCommandPlugin` — SPM
  plugins that invoke `swa` via subprocess. They cannot use
  `ProcessExecutor` because SPM plugin hosts are sandbox-locked to
  `PackagePlugin + Foundation`.
