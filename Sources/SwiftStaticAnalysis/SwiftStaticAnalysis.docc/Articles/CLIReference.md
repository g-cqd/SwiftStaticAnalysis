# CLI Reference

Complete reference for the `swa` command-line tool.

## Overview

The `swa` (Swift Static Analysis) CLI provides commands for detecting unused code and code duplication in Swift projects, plus symbol lookup.

## Installation

### From Source

```bash
git clone https://github.com/g-cqd/SwiftStaticAnalysis.git
cd SwiftStaticAnalysis
swift build -c release
cp .build/release/swa /usr/local/bin/
```

### Using Swift Package Manager Plugin

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/g-cqd/SwiftStaticAnalysis.git", from: "0.1.2")
]
```

Then run:

```bash
swift package plugin analyze
```

## Commands

### analyze

Run full analysis (duplicates + unused code).

```bash
swa analyze [OPTIONS] <PATHS>...
```

#### Arguments

- `<PATHS>`: One or more paths to Swift files or directories to analyze.

#### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--config <PATH>` | Path to configuration file (.swa.json) | - |
| `-f, --format <FORMAT>` | Output format: `text`, `json`, `xcode` | `xcode` |

#### Examples

```bash
# Full analysis
swa analyze Sources/

# JSON output
swa analyze . --format json > report.json
```

### duplicates

Detect code duplication in Swift files.

```bash
swa duplicates [OPTIONS] <PATHS>...
```

#### Arguments

- `<PATHS>`: One or more paths to Swift files or directories to analyze.

#### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--types <TYPE>` | Clone types: `exact`, `near`, `semantic` (repeatable) | `exact` |
| `--min-tokens <N>` | Minimum tokens for a clone | `50` |
| `--min-similarity <RATIO>` | Minimum similarity (0.0-1.0) | `0.8` |
| `--algorithm <ALG>` | Algorithm: `rollingHash`, `suffixArray`, `minHashLSH` | `rollingHash` |
| `--exclude-paths <GLOB>` | Paths to exclude (repeatable) | - |
| `--parallel-mode <MODE>` | Parallel mode: `none`, `safe`, `maximum` | `none` |
| `--parallel` | Deprecated: use `--parallel-mode` | `false` |
| `--config <PATH>` | Path to configuration file (.swa.json) | - |
| `-f, --format <FORMAT>` | Output format: `text`, `json`, `xcode` | `xcode` |

Parallel modes: `none` (sequential), `safe` (TaskGroup parallelism), `maximum` (streaming/backpressure for large pipelines). `--parallel` maps to `safe`.

#### Examples

```bash
# Basic duplication detection
swa duplicates Sources/

# Detect near-clones with lower threshold
swa duplicates --types exact --types near --min-similarity 0.7 Sources/

# High-performance exact detection
swa duplicates --algorithm suffixArray --min-tokens 30 Sources/

# Parallel MinHash/LSH (large codebases)
swa duplicates --types near --algorithm minHashLSH --parallel-mode safe Sources/
```

### unused

Detect unused code in Swift files.

```bash
swa unused [OPTIONS] <PATHS>...
```

#### Arguments

- `<PATHS>`: One or more paths to Swift files or directories to analyze.

#### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--mode <MODE>` | Detection mode: `simple`, `reachability`, `indexStore` | `simple` |
| `--min-confidence <LEVEL>` | Minimum confidence: `low`, `medium`, `high` | `medium` |
| `--ignore-public` | Ignore public declarations | `false` |
| `--index-store-path <PATH>` | Path to IndexStore database | - |
| `--report` | Generate reachability report | `false` |
| `--parallel-mode <MODE>` | Parallel mode: `none`, `safe`, `maximum` | `none` |
| `--parallel` | Deprecated: use `--parallel-mode` | `false` |
| `--exclude-paths <GLOB>` | Paths to exclude (repeatable) | - |
| `--exclude-imports` | Exclude import statements | `false` |
| `--exclude-test-suites` | Exclude test suite declarations | `false` |
| `--exclude-enum-cases` | Exclude backticked enum cases | `false` |
| `--exclude-deinit` | Exclude deinit methods | `false` |
| `--sensible-defaults` | Apply common exclusions | `false` |
| `--treat-public-as-root` | Treat public API as entry points | `false` |
| `--treat-objc-as-root` | Treat @objc declarations as entry points | `false` |
| `--treat-tests-as-root` | Treat test methods as entry points | `false` |
| `--treat-swift-ui-views-as-root` | Treat SwiftUI Views as entry points | `false` |
| `--ignore-swift-ui-property-wrappers` | Ignore SwiftUI property wrappers | `false` |
| `--ignore-preview-providers` | Ignore PreviewProvider implementations | `false` |
| `--ignore-view-body` | Ignore View body properties | `false` |
| `--config <PATH>` | Path to configuration file (.swa.json) | - |
| `-f, --format <FORMAT>` | Output format: `text`, `json`, `xcode` | `xcode` |

Parallel modes: `none` (sequential), `safe` (TaskGroup parallelism), `maximum` (streaming/backpressure for large pipelines). `--parallel` maps to `safe`.

#### Examples

```bash
# Simple analysis of a directory
swa unused Sources/

# Reachability-based analysis with JSON output
swa unused --mode reachability --format json Sources/

# Parallel reachability on large graphs
swa unused --mode reachability --parallel-mode safe Sources/

# IndexStore-based analysis (requires prior build)
swa unused --mode indexStore --index-store-path .build/debug/index/store Sources/

# Ignore public API for library development
swa unused --ignore-public Sources/

# Apply sensible defaults
swa unused --sensible-defaults Sources/
```

### symbol

Look up symbols in Swift source files.

```bash
swa symbol [OPTIONS] <QUERY> <PATHS>...
```

#### Arguments

- `<QUERY>`: Symbol name, qualified name (Type.member), selector (method(param:)), regex, or USR.
- `<PATHS>`: One or more paths to Swift files or directories to analyze.

#### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--usr` | Treat query as USR directly | `false` |
| `--kind <KIND>` | Filter by kind: `function`, `method`, `variable`, `constant`, `class`, `struct`, `enum`, `protocol`, `initializer` | - |
| `--access <LEVEL>` | Filter by access: `private`, `fileprivate`, `internal`, `public`, `open` | - |
| `--in-type <TYPE>` | Search within type scope | - |
| `--definition` | Show only definitions | `false` |
| `--usages` | Show usages/references | `false` |
| `--index-store-path <PATH>` | Path to IndexStore database | - |
| `--limit <N>` | Maximum results to return | - |
| `-f, --format <FORMAT>` | Output format: `text`, `json`, `xcode` | `text` |

#### Context Options

Extract contextual information around matched symbols:

| Option | Description | Default |
|--------|-------------|---------|
| `--context-lines <N>` | Lines of context before and after symbol | - |
| `--context-before <N>` | Lines of context before symbol | - |
| `--context-after <N>` | Lines of context after symbol | - |
| `--context-scope` | Include containing scope information | `false` |
| `--context-signature` | Include complete signature | `false` |
| `--context-body` | Include declaration body | `false` |
| `--context-documentation` | Include documentation comments | `false` |
| `--context-all` | Include all context information | `false` |

#### Query Patterns

| Pattern | Example | Description |
|---------|---------|-------------|
| Simple name | `NetworkManager` | Find by symbol name |
| Qualified name | `APIClient.shared` | Find member in type |
| Selector | `fetch(id:completion:)` | Find method by signature |
| Regex | `/^handle.*Event$/` | Find by pattern match |
| USR | `s:14NetworkMonitor6sharedACvpZ` | Find by compiler USR (with `--usr`) |

#### Examples

```bash
# Find class by name
swa symbol NetworkManager Sources/

# Find qualified member
swa symbol "APIClient.shared" Sources/

# Find method by selector
swa symbol "fetch(id:completion:)" Sources/

# Filter by kind
swa symbol shared --kind variable --kind constant Sources/

# Filter by access level
swa symbol Manager --access public Sources/

# Show only definitions
swa symbol NetworkManager --definition Sources/

# Show all usages of a symbol
swa symbol "Cache.shared" --usages Sources/

# Use IndexStore for faster lookup
swa symbol NetworkManager --index-store-path .build/debug/index/store Sources/

# JSON output for tooling
swa symbol "APIClient" --format json Sources/

# Show 3 lines of context before and after
swa symbol "NetworkManager" --context-lines 3 Sources/

# Include documentation and signature
swa symbol "fetchData" --context-documentation --context-signature Sources/

# Show containing scope
swa symbol "processItem" --context-scope Sources/

# Include function body
swa symbol "validate" --context-body Sources/

# All context in JSON format (for LLM prompts)
swa symbol "CacheManager" --context-all --format json Sources/
```

## Configuration File

Create a `.swa.json` file in your project root for persistent configuration.

### Schema

```json
{
  "version": 1,
  "format": "xcode",
  "excludePaths": ["**/Tests/**", "**/Fixtures/**"],
  "unused": {
    "enabled": true,
    "mode": "reachability",
    "indexStorePath": ".build/debug/index/store",
    "minConfidence": "medium",
    "ignorePublicAPI": false,
    "sensibleDefaults": true,
    "excludeImports": true,
    "excludeDeinit": true,
    "excludeEnumCases": true,
    "excludeTestSuites": true,
    "excludePaths": ["**/Tests/**"],
    "treatPublicAsRoot": false,
    "treatObjcAsRoot": false,
    "treatTestsAsRoot": false,
    "treatSwiftUIViewsAsRoot": false,
    "ignoreSwiftUIPropertyWrappers": false,
    "ignorePreviewProviders": false,
    "ignoreViewBody": false,
    "parallelMode": "none"
  },
  "duplicates": {
    "enabled": true,
    "minTokens": 50,
    "minSimilarity": 0.8,
    "types": ["exact", "near"],
    "algorithm": "rollingHash",
    "excludePaths": ["**/Generated/**"],
    "parallelMode": "none"
  }
}
```

`parallelMode` accepts `none`, `safe`, or `maximum`. The legacy `parallel` boolean is still supported but deprecated.

### Example Configurations

#### Library Development

```json
{
  "unused": {
    "mode": "reachability",
    "ignorePublicAPI": true,
    "minConfidence": "high"
  }
}
```

#### Application Development

```json
{
  "unused": {
    "mode": "reachability",
    "treatPublicAsRoot": false,
    "minConfidence": "medium"
  }
}
```

#### CI/CD Integration

```json
{
  "unused": {
    "mode": "simple",
    "minConfidence": "high"
  },
  "duplicates": {
    "minTokens": 100,
    "minSimilarity": 0.9
  },
  "format": "xcode"
}
```

## Output Formats

### text (default)

Human-readable output with file paths and line numbers.

```
[high] Sources/Models/User.swift:15:5: Consider removing unused function 'legacyValidate'
[medium] Sources/Utils/Helpers.swift:42:1: Consider removing unused struct 'DeprecatedCache'
```

### json

Machine-readable JSON output for tooling integration.

```json
{
  "clones": [
    {
      "clones": [
        {
          "codeSnippet": "func foo() { ... }",
          "endLine": 20,
          "file": "Sources/A.swift",
          "startLine": 10,
          "tokenCount": 42
        }
      ],
      "fingerprint": "f1a2b3c4",
      "similarity": 1,
      "type": "exact"
    }
  ],
  "unused": [
    {
      "confidence": "high",
      "declaration": {
        "kind": "function",
        "location": {"column": 5, "file": "Sources/Models/User.swift", "line": 15},
        "name": "legacyValidate"
      },
      "reason": "noReferences",
      "suggestion": "Consider removing unused function 'legacyValidate'"
    }
  ]
}
```

### xcode

Xcode-compatible output for build phase integration.

```
Sources/Models/User.swift:15:5: warning: Consider removing unused function 'legacyValidate'
```

## Exit Status

`swa` returns a non-zero status only for errors (invalid arguments, missing files, or runtime failures). It does not currently fail the build when issues are found.

## Ignore Directives

Add comments to source files to suppress specific warnings.

### Syntax

```swift
// swa:ignore
func intentionallyUnused() { }

// swa:ignore-unused
class LegacySupport { }

/// Documentation comment. // swa:ignore-unused-cases
enum AllCases {
    case a, b, c  // All cases inherit the ignore directive
}

/* swa:ignore */
struct IgnoredStruct { }

// swa:ignore-duplicates
func generatedHandler() {
    // This won't be flagged as a duplicate
}

// swa:ignore-duplicates:begin
struct GeneratedModel1 { }
struct GeneratedModel2 { }
// swa:ignore-duplicates:end
```

### Directive Types

| Directive | Description |
|-----------|-------------|
| `swa:ignore` | Ignore all warnings for this declaration |
| `swa:ignore-unused` | Ignore unused code warnings |
| `swa:ignore-unused-cases` | Ignore unused enum case warnings (inherits to cases) |
| `swa:ignore-duplicates` | Ignore duplication warnings for this declaration |
| `swa:ignore-duplicates:begin` | Start of region to ignore for duplication |
| `swa:ignore-duplicates:end` | End of region to ignore for duplication |

## SwiftUI Support

The tool includes SwiftUI-aware heuristics you can toggle via flags:

- **Property Wrappers**: `@State`, `@Binding`, `@ObservedObject`, `@EnvironmentObject`, `@Published`, `@Environment`
- **Preview Providers**: `PreviewProvider` conforming types
- **View Body**: `body` property in `View` conforming types
- **View Protocol**: Types conforming to `View`

## Build Plugin Integration

### Xcode Build Phase

Add to your scheme's Build phase:

```bash
if which swa >/dev/null; then
  swa unused --format xcode Sources/
else
  echo "warning: swa not installed"
fi
```

### Swift Package Manager

Use the included build plugin:

```swift
targets: [
    .target(
        name: "MyTarget",
        plugins: [
            .plugin(name: "StaticAnalysisBuildPlugin", package: "SwiftStaticAnalysis")
        ]
    )
]
```

Or use the command plugin:

```bash
swift package plugin analyze
```

## See Also

- <doc:GettingStarted>
- <doc:UnusedCodeDetection>
- <doc:CloneDetection>
- <doc:SymbolLookup>
- <doc:MCPServer>
- <doc:CIIntegration>
