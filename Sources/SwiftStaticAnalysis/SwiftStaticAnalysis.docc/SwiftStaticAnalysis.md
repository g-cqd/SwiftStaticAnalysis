# ``SwiftStaticAnalysis``

A high-performance Swift static analysis framework for code duplication detection and unused code elimination.

## Overview

SwiftStaticAnalysis provides comprehensive tools for analyzing Swift codebases to find duplicated code patterns and unused declarations. The framework is designed for performance with memory-mapped I/O, arena allocation, and parallel processing.

## Modules

The framework consists of three main modules:

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

### UnusedCodeDetector

Unused code detection with configurable modes:
- **Simple Mode**: Fast syntax-based detection
- **Reachability Mode**: Graph-based dead code analysis
- **IndexStore Mode**: Cross-module accuracy using compiler index

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:CLIReference>

### Detection

- <doc:CloneDetection>
- <doc:UnusedCodeDetection>

### Configuration

- <doc:IgnoreDirectives>
- <doc:CIIntegration>

### Advanced

- <doc:PerformanceOptimization>
