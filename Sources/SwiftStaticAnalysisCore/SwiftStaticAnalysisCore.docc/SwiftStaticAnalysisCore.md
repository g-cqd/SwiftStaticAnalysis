# ``SwiftStaticAnalysisCore``

A high-performance Swift static analysis framework for code duplication detection and unused code elimination.

## Overview

SwiftStaticAnalysis provides powerful tools to analyze Swift codebases for quality issues:

- **Clone Detection**: Find exact, near, and semantic code duplicates using advanced algorithms
- **Unused Code Detection**: Identify dead code with configurable accuracy modes
- **Performance Optimized**: Memory-mapped I/O, arena allocation, and parallel processing
- **Xcode Integration**: Output warnings in Xcode-compatible format

The framework consists of three main modules:

| Module | Purpose |
|--------|---------|
| ``SwiftStaticAnalysisCore`` | Core infrastructure, parsing, and AST visitors |
| `DuplicationDetector` | Clone detection with Suffix Array, MinHash, and AST fingerprinting |
| `UnusedCodeDetector` | Unused code detection with IndexStoreDB and reachability analysis |

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:CLIReference>
- <doc:CloneDetection>
- <doc:UnusedCodeDetection>

### Configuration

- <doc:IgnoreDirectives>
- <doc:PerformanceOptimization>

### Integration

- <doc:CIIntegration>

### Core Types

- ``Declaration``
- ``DeclarationKind``
- ``Reference``
- ``SourceLocation``
- ``AnalysisResult``

### Parsing

- ``SwiftFileParser``
- ``ConcurrencyConfiguration``

### Visitors

- ``DeclarationCollector``
- ``ReferenceCollector``
- ``ScopeTracker``
