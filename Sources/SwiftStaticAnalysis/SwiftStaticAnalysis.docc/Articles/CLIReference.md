# CLI Reference

Complete reference for the `swa` command-line tool.

## Overview

The `swa` (Swift Static Analysis) CLI provides commands for detecting unused code and code duplication in Swift projects.

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
    .package(url: "https://github.com/g-cqd/SwiftStaticAnalysis.git", from: "0.0.19")
]
```

Then run:

```bash
swift package plugin analyze
```

## Commands

### symbol

Look up symbols in Swift source files.

```bash
swa symbol [OPTIONS] <QUERY> <PATHS>...
```

#### Arguments

- `<QUERY>`: Symbol name, qualified name (Type.member), selector (method(param:)), or USR.
- `<PATHS>`: One or more paths to Swift files or directories to analyze.

#### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--usr` | Treat query as USR directly | `false` |
| `--kind <KIND>` | Filter by kind: `function`, `method`, `variable`, `class`, `struct`, `enum`, `protocol`, `initializer` | - |
| `--access <LEVEL>` | Filter by access: `private`, `fileprivate`, `internal`, `public`, `open` | - |
| `--in-type <TYPE>` | Search within type scope | - |
| `--definition` | Show only definitions | `false` |
| `--usages` | Show usages/references | `false` |
| `--index-store-path <PATH>` | Path to IndexStore database | - |
| `--limit <N>` | Maximum results to return | - |
| `--format <FORMAT>` | Output format: `text`, `json`, `xcode` | `text` |

#### Query Patterns

| Pattern | Example | Description |
|---------|---------|-------------|
| Simple name | `NetworkManager` | Find by symbol name |
| Qualified name | `APIClient.shared` | Find member in type |
| Selector | `fetch(id:completion:)` | Find method by signature |
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
swa symbol shared --kind variable --kind property Sources/

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
| `--ignore-public-api` | Ignore public declarations | `false` |
| `--treat-public-as-root` | Treat public API as reachability roots | `true` |
| `--treat-objc-as-root` | Treat @objc declarations as roots | `true` |
| `--treat-tests-as-root` | Treat test methods as roots | `true` |
| `--treat-swift-ui-views-as-root` | Treat SwiftUI views as roots | `true` |
| `--ignore-swift-ui-property-wrappers` | Ignore @State, @Binding, etc. | `true` |
| `--ignore-preview-providers` | Ignore PreviewProvider types | `true` |
| `--ignore-view-body` | Ignore SwiftUI body properties | `true` |
| `--index-store-path <PATH>` | Path to IndexStore database | - |
| `--format <FORMAT>` | Output format: `text`, `json`, `xcode` | `text` |
| `--output <FILE>` | Write output to file | stdout |
| `--config <PATH>` | Path to configuration file | `.swa.json` |
| `-v, --verbose` | Enable verbose output | `false` |

#### Examples

```bash
# Simple analysis of a directory
swa unused Sources/

# Reachability-based analysis with JSON output
swa unused --mode reachability --format json Sources/

# IndexStore-based analysis (requires prior build)
swa unused --mode indexStore --index-store-path .build/debug/index/store Sources/

# Ignore public API for library development
swa unused --ignore-public-api Sources/

# High confidence only
swa unused --min-confidence high Sources/

# Xcode-compatible output for CI integration
swa unused --format xcode Sources/
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
| `--min-tokens <N>` | Minimum tokens for a clone | `50` |
| `--min-similarity <RATIO>` | Minimum similarity (0.0-1.0) | `0.8` |
| `--clone-types <TYPES>` | Clone types: `exact`, `near`, `semantic` | `exact,near` |
| `--algorithm <ALG>` | Algorithm: `rollingHash`, `suffixArray`, `minHashLSH` | `rollingHash` |
| `--format <FORMAT>` | Output format: `text`, `json`, `xcode` | `text` |
| `--output <FILE>` | Write output to file | stdout |
| `--config <PATH>` | Path to configuration file | `.swa.json` |
| `-v, --verbose` | Enable verbose output | `false` |

#### Clone Types

- **exact**: Identical code blocks (Type-1 clones)
- **near**: Similar code with renamed identifiers/literals (Type-2 clones)
- **semantic**: Structurally equivalent code (Type-3 clones)

#### Algorithms

- **rollingHash**: Fast rolling hash algorithm, good for most cases
- **suffixArray**: O(n log n) suffix array for high-performance exact detection
- **minHashLSH**: LSH-based probabilistic detection for large codebases

#### Examples

```bash
# Basic duplication detection
swa duplicates Sources/

# Detect near-clones with lower threshold
swa duplicates --clone-types exact,near --min-similarity 0.7 Sources/

# High-performance mode for large codebases
swa duplicates --algorithm suffixArray --min-tokens 30 Sources/

# JSON output for tooling integration
swa duplicates --format json --output duplicates.json Sources/
```

## Configuration File

Create a `.swa.json` file in your project root for persistent configuration.

### Schema

```json
{
  "unused": {
    "mode": "reachability",
    "minConfidence": "medium",
    "ignorePublicAPI": false,
    "treatPublicAsRoot": true,
    "treatObjcAsRoot": true,
    "treatTestsAsRoot": true,
    "treatSwiftUIViewsAsRoot": true,
    "ignoreSwiftUIPropertyWrappers": true,
    "ignorePreviewProviders": true,
    "ignoreViewBody": true,
    "excludePaths": [
      "**/Tests/**",
      "**/Fixtures/**"
    ],
    "excludeNames": [
      "^_.*"
    ]
  },
  "duplicates": {
    "minTokens": 50,
    "minSimilarity": 0.8,
    "cloneTypes": ["exact", "near"],
    "algorithm": "rollingHash",
    "excludePaths": [
      "**/Generated/**"
    ]
  },
  "format": "text",
  "verbose": false
}
```

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
Unused Code Report
==================
Found 3 unused declarations

src/Models/User.swift:15:5
  warning: Unused function 'legacyValidate'
  Confidence: high
  Reason: Never referenced

src/Utils/Helpers.swift:42:1
  warning: Unused struct 'DeprecatedCache'
  Confidence: medium
  Reason: Only referenced by other unused code
```

### json

Machine-readable JSON output for tooling integration.

```json
{
  "unusedCode": [
    {
      "file": "src/Models/User.swift",
      "line": 15,
      "column": 5,
      "name": "legacyValidate",
      "kind": "function",
      "confidence": "high",
      "reason": "neverReferenced"
    }
  ],
  "summary": {
    "totalDeclarations": 150,
    "unusedCount": 3,
    "byKind": {
      "function": 2,
      "struct": 1
    }
  }
}
```

### xcode

Xcode-compatible output for build phase integration.

```
src/Models/User.swift:15:5: warning: Unused function 'legacyValidate' [swa-unused]
src/Utils/Helpers.swift:42:1: warning: Unused struct 'DeprecatedCache' [swa-unused]
```

## Exit Codes

| Code | Description |
|------|-------------|
| 0 | Success (no issues found or analysis completed) |
| 1 | Analysis found issues |
| 2 | Invalid arguments or configuration |
| 3 | File not found or unreadable |
| 4 | Internal error |

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

The tool includes special handling for SwiftUI patterns:

- **Property Wrappers**: `@State`, `@Binding`, `@ObservedObject`, `@EnvironmentObject`, `@Published`, `@Environment` are recognized as used
- **Preview Providers**: `PreviewProvider` conforming types are treated as roots
- **View Body**: The `body` property in `View` conforming types is treated as used
- **View Protocol**: Types conforming to `View` can be treated as roots

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

- ``GettingStarted``
- ``UnusedCodeDetection``
- ``CloneDetection``
- ``CIIntegration``
