# Unused Code Detection

Identify dead code with configurable accuracy and performance trade-offs.

## Overview

Unused code increases maintenance burden, slows compilation, and can hide bugs. SwiftStaticAnalysis offers three detection modes with different accuracy/speed trade-offs.

## Detection Modes

| Mode | Speed | Accuracy | Best For |
|------|-------|----------|----------|
| `simple` | Fast | ~70% | Quick scans, large codebases |
| `reachability` | Medium | ~85% | Entry-point based dead code |
| `indexStore` | Slow | ~95% | Cross-module, protocol witnesses |

### Simple Mode

Compares declarations against references using SwiftSyntax parsing only.

```bash
swa unused . --mode simple
```

**Limitations**:
- Cannot detect cross-module usage
- May miss protocol witness implementations
- No index data means some false positives

### Reachability Mode

Builds a dependency graph from entry points (main, @main, public API) and marks reachable code.

```bash
swa unused . --mode reachability
```

**Features**:
- Graph-based dead code detection
- Entry point analysis
- Better handling of indirect usage
- Parallel edge computation and batch insertion for large graphs
- Optional direction-optimizing parallel BFS (experimental, use `--parallel-mode safe`)

Generate a reachability report:

```bash
swa unused . --mode reachability --report
```

Output:
```
=== Reachability Report ===
Total declarations: 450
Root nodes: 12
Reachable: 380
Unreachable: 70
Reachability: 84.4%

Roots by reason:
  - publicAPI: 8
  - mainEntry: 1
  - testEntry: 3

Unreachable by kind:
  - function: 45
  - variable: 15
  - struct: 10
```

#### Parallel Reachability (Experimental)

Enable direction-optimizing parallel BFS for large reachability graphs:

```bash
swa unused . --mode reachability --parallel-mode safe
```

This uses a top-down/bottom-up hybrid BFS with automatic fallback to sequential traversal on small graphs.
`--parallel` is deprecated and maps to `--parallel-mode safe`.

### IndexStore Mode

Uses the compiler's index store for cross-module accuracy and protocol witness detection.

```bash
swa unused . --mode indexStore --index-store-path .build/debug/index/store
```

**Features**:
- Cross-module reference tracking
- Protocol witness detection
- Highest accuracy

**Requirements**:
- Build your project first to generate the index store
- Specify the index store path (or let SwiftStaticAnalysis auto-discover it in `.build/.../index/store` or Xcode DerivedData)

## Filtering Options

### Built-in Exclusions

```bash
# Exclude import statements
swa unused . --exclude-imports

# Exclude deinit methods (often required by ARC)
swa unused . --exclude-deinit

# Exclude backticked enum cases (Swift keywords)
swa unused . --exclude-enum-cases

# Exclude test suite declarations
swa unused . --exclude-test-suites

# Apply all sensible defaults at once
swa unused . --sensible-defaults
```

Declarations or parameters named `_` are always skipped as explicitly unused.

### Path Exclusions

Use glob patterns to exclude directories:

```bash
swa unused . --exclude-paths "**/Tests/**" --exclude-paths "**/Fixtures/**"
```

### Ignoring Public API

For libraries, public API may appear unused but is intentionally exposed:

```bash
swa unused . --ignore-public
```

## Programmatic API

### Basic Usage

```swift
import SwiftStaticAnalysis

let detector = UnusedCodeDetector()
let unused = try await detector.detectUnused(in: swiftFiles)

for item in unused {
    print("[\(item.confidence)] \(item.declaration.name): \(item.suggestion)")
}
```

### With Configuration

```swift
import SwiftStaticAnalysis

// Reachability mode
let config = UnusedCodeConfiguration(
    ignorePublicAPI: true,
    mode: .reachability
)

let detector = UnusedCodeDetector(configuration: config)
let unused = try await detector.detectUnused(in: swiftFiles)
```

### Parallel Reachability (Programmatic)

```swift
var config = UnusedCodeConfiguration.reachability
config.useParallelBFS = true

let detector = UnusedCodeDetector(configuration: config)
let unused = try await detector.detectUnused(in: swiftFiles)
```

### Streaming Edge Extraction (Advanced)

Stream dependency edges as they are computed to reduce peak memory:

```swift
let extractor = DependencyExtractor()
for await edge in extractor.streamEdges(from: analysisResult) {
    handle(edge)
}
```

### IndexStore Mode

```swift
import SwiftStaticAnalysis

var config = UnusedCodeConfiguration.indexStore
config.indexStorePath = ".build/debug/index/store"

let detector = UnusedCodeDetector(configuration: config)
let unused = try await detector.detectUnused(in: swiftFiles)
```

### Filtering Results

```swift
// Filter with sensible defaults
let filtered = unused.filteredWithSensibleDefaults()

// Custom filtering
let customFiltered = unused.filter { item in
    // Keep only high-confidence results
    item.confidence == .high &&
    // Exclude test files
    !item.declaration.location.file.contains("/Tests/")
}
```

## Dataflow Analysis Notes

Unused variable detection uses scope-aware identifiers (scope depth + declaration line) to avoid false matches across nested scopes. Tuple pattern bindings and destructuring are expanded into individual variables, and captured variables in closures are conservatively marked as used.

Implementation sources:
- `Sources/UnusedCodeDetector/DataFlow/CFGBuilder.swift`
- `Sources/UnusedCodeDetector/DataFlow/LiveVariableAnalysis.swift`
- `Sources/UnusedCodeDetector/DataFlow/ReachingDefinitions.swift`
- `Sources/UnusedCodeDetector/DataFlow/SCCPAnalysis.swift`

## Confidence Levels

Each result includes a confidence level:

| Level | Meaning |
|-------|---------|
| `high` | Very likely unused, safe to remove |
| `medium` | Probably unused, review before removing |
| `low` | Potentially unused, may have indirect usage |

The confidence is calculated based on:
- Declaration visibility (private > internal > public)
- Declaration kind (variables > functions > types)
- Reference patterns (no references vs. self-references only)

## Common False Positives

1. **Protocol witnesses** - Implementations required by protocol conformance
2. **Objective-C interop** - `@objc` methods called from Objective-C
3. **Reflection/runtime** - Code accessed via `Mirror` or selectors
4. **Codable synthesis** - Properties used by `Codable` conformance
5. **SwiftUI previews** - Preview providers

Use <doc:IgnoreDirectives> to suppress known false positives.

## Implementation Sources

- `Sources/UnusedCodeDetector/Reachability/ParallelBFS.swift` (direction-optimizing BFS)
- `Sources/UnusedCodeDetector/Reachability/DenseGraph.swift` and `Sources/UnusedCodeDetector/Reachability/Bitmap.swift`
- `Sources/UnusedCodeDetector/Reachability/DependencyExtractor.swift` (parallel edge building)
- `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift` (index store discovery)
- `PARALLEL_BFS_STUDY.md` and `PARALLEL_BFS_IMPLEMENTATION_STUDY.md`

## See Also

- <doc:IgnoreDirectives>
- <doc:CloneDetection>
- <doc:CIIntegration>
