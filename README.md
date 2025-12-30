# SwiftStaticAnalysis

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2015%2B-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![CI](https://github.com/g-cqd/SwiftStaticAnalysis/actions/workflows/ci.yml/badge.svg)](https://github.com/g-cqd/SwiftStaticAnalysis/actions/workflows/ci.yml)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blue.svg)](https://g-cqd.github.io/SwiftStaticAnalysis/documentation/swiftstaticanalysiscore/)

A high-performance Swift static analysis framework for **code duplication detection** and **unused code elimination**.

## Features

- **Multi-Algorithm Clone Detection**: Exact (Type-1), near (Type-2), and semantic (Type-3/4) clone detection
- **IndexStoreDB Integration**: Accurate cross-module unused code detection using compiler index data
- **Reachability Analysis**: Graph-based dead code detection with entry point tracking
- **Ignore Directives**: Suppress false positives with `// swa:ignore` comments
- **High-Performance Parsing**: Memory-mapped I/O, SoA token storage, and arena allocation
- **Zero-Boilerplate CLI**: Full-featured `swa` command with JSON/text/Xcode output formats
- **Swift 6 Concurrency**: Thread-safe design with `Sendable` conformance throughout
- **Configurable Filtering**: Exclude imports, test suites, deinit methods, and custom patterns

## Requirements

- macOS 15.0+
- Swift 6.2+
- Xcode 26.0+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/g-cqd/SwiftStaticAnalysis.git", from: "0.1.0")
]
```

Then add the products you need:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SwiftStaticAnalysisCore", package: "SwiftStaticAnalysis"),
        .product(name: "DuplicationDetector", package: "SwiftStaticAnalysis"),
        .product(name: "UnusedCodeDetector", package: "SwiftStaticAnalysis"),
    ]
)
```

### Pre-built Binary (Recommended)

Download the latest release from GitHub:

```bash
# Universal binary (works on both Apple Silicon and Intel)
curl -L https://github.com/g-cqd/SwiftStaticAnalysis/releases/latest/download/swa-macos-universal.tar.gz | tar xz
sudo mv swa /usr/local/bin/

# Or for Apple Silicon only
curl -L https://github.com/g-cqd/SwiftStaticAnalysis/releases/latest/download/swa-macos-arm64.tar.gz | tar xz

# Or for Intel only
curl -L https://github.com/g-cqd/SwiftStaticAnalysis/releases/latest/download/swa-macos-x86_64.tar.gz | tar xz
```

### Build from Source

```bash
# Build release binary
swift build -c release

# Install to PATH
cp .build/release/swa /usr/local/bin/
```

## Quick Start

### CLI Usage

```bash
# Full analysis (duplicates + unused code)
swa analyze /path/to/project

# Detect code duplicates
swa duplicates /path/to/project --types exact --types near --types semantic

# Detect unused code with reachability analysis
swa unused /path/to/project --mode reachability

# Apply sensible filters to reduce false positives
swa unused . --sensible-defaults --exclude-paths "**/Tests/**"

# Output as JSON for CI integration
swa analyze . --format json > report.json

# Xcode-compatible warnings
swa unused . --format xcode
```

### Configuration File

Create a `.swa.json` file in your project root for persistent configuration:

```json
{
  "unused": {
    "mode": "reachability",
    "minConfidence": "medium",
    "excludePaths": ["**/Tests/**", "**/Fixtures/**"],
    "excludeImports": true,
    "excludeTestSuites": true,
    "treatPublicAsRoot": true,
    "treatSwiftUIViewsAsRoot": true
  },
  "duplicates": {
    "types": ["exact", "near"],
    "minTokens": 50,
    "minSimilarity": 0.8,
    "algorithm": "suffixArray"
  }
}
```

Then run with:

```bash
swa analyze --config .swa.json
```

### Programmatic API

#### Duplication Detection

```swift
import DuplicationDetector

let config = DuplicationConfiguration(
    minimumTokens: 50,
    cloneTypes: [.exact, .near, .semantic],
    minimumSimilarity: 0.8
)

let detector = DuplicationDetector(configuration: config)
let clones = try await detector.detectClones(in: swiftFiles)

for group in clones {
    print("[\(group.type.rawValue)] \(group.occurrences) occurrences")
    for clone in group.clones {
        print("  \(clone.file):\(clone.startLine)-\(clone.endLine)")
    }
}
```

#### Unused Code Detection

```swift
import UnusedCodeDetector

// Use reachability analysis for accurate detection
let config = UnusedCodeConfiguration.reachability

let detector = UnusedCodeDetector(configuration: config)
let unused = try await detector.detectUnused(in: swiftFiles)

// Filter results with sensible defaults
let filtered = unused.filteredWithSensibleDefaults()

for item in filtered {
    print("[\(item.confidence.rawValue)] \(item.declaration.location): \(item.suggestion)")
}
```

#### IndexStore-Enhanced Detection

```swift
import UnusedCodeDetector

// Use compiler's index data for cross-module accuracy
var config = UnusedCodeConfiguration.indexStore
config.indexStorePath = ".build/debug/index/store"
config.autoBuild = true  // Build if index is stale

let detector = UnusedCodeDetector(configuration: config)
let unused = try await detector.detectUnused(in: swiftFiles)
```

## Ignore Directives

Suppress false positives directly in your source code using `// swa:ignore` comments.

### Supported Formats

```swift
// swa:ignore                    - Ignore all warnings for this declaration
// swa:ignore-unused             - Ignore unused code warnings
// swa:ignore-unused-cases       - Ignore unused enum case warnings (for exhaustive enums)
/// Doc comment. // swa:ignore   - Also works in doc comments
/* swa:ignore */                 - Block comments work too
```

### Example Usage

```swift
/// Known error types for API responses.
/// Exhaustive for serialization. // swa:ignore-unused-cases
public enum APIError: String, Codable {
    case networkError
    case authenticationFailed
    case serverError      // May not be used yet, but needed for API compatibility
    case rateLimited
}

// swa:ignore
func debugHelper() {
    // Intentionally unused in production, used only during development
}
```

### Enum Case Inheritance

When you mark an enum with `// swa:ignore-unused-cases`, all its cases automatically inherit the directive:

```swift
/// Protocol message types. // swa:ignore-unused-cases
enum MessageType {
    case request    // ← Automatically ignored
    case response   // ← Automatically ignored
    case error      // ← Automatically ignored
}
```

## Detection Modes

| Mode | Speed | Accuracy | Use Case |
|------|-------|----------|----------|
| `simple` | Fast | ~70% | Quick scans, large codebases |
| `reachability` | Medium | ~85% | Entry-point based dead code detection |
| `indexStore` | Slow | ~95% | Cross-module, protocol witnesses |

## Clone Types

| Type | Description | Algorithm |
|------|-------------|-----------|
| **Exact** (Type-1) | Identical code, whitespace-normalized | Suffix Array (SA-IS) |
| **Near** (Type-2) | Renamed variables/literals | MinHash + LSH |
| **Semantic** (Type-3/4) | Functionally equivalent | AST Fingerprinting |

## Filtering Options

Reduce false positives with built-in filters:

```bash
# Exclude import statements
swa unused . --exclude-imports

# Exclude test suite declarations
swa unused . --exclude-test-suites

# Exclude deinit methods
swa unused . --exclude-deinit

# Exclude backticked enum cases (Swift keywords)
swa unused . --exclude-enum-cases

# Exclude paths with glob patterns
swa unused . --exclude-paths "**/Tests/**" --exclude-paths "**/Fixtures/**"

# Apply all sensible defaults at once
swa unused . --sensible-defaults
```

## CLI Reference

### `swa analyze`

Run full analysis (duplicates + unused code).

```bash
swa analyze [<path>] [options]
```

| Option | Description |
|--------|-------------|
| `--config <path>` | Path to configuration file (.swa.json) |
| `-f, --format <format>` | Output format: `text`, `json`, `xcode` (default: xcode) |

### `swa unused`

Detect unused code.

```bash
swa unused [<path>] [options]
```

| Option | Description |
|--------|-------------|
| `--config <path>` | Path to configuration file |
| `--mode <mode>` | Detection mode: `simple`, `reachability`, `indexStore` |
| `--min-confidence <level>` | Minimum confidence: `low`, `medium`, `high` |
| `--index-store-path <path>` | Path to index store (for indexStore mode) |
| `--report` | Generate reachability report |
| `-f, --format <format>` | Output format: `text`, `json`, `xcode` |
| `--exclude-paths <glob>` | Paths to exclude (repeatable) |
| `--exclude-imports` | Exclude import statements |
| `--exclude-test-suites` | Exclude test suite declarations |
| `--exclude-enum-cases` | Exclude backticked enum cases |
| `--exclude-deinit` | Exclude deinit methods |
| `--sensible-defaults` | Apply all sensible defaults |
| `--ignore-public` | Ignore public API |
| `--treat-public-as-root` | Treat public API as entry points |
| `--treat-objc-as-root` | Treat @objc declarations as entry points |
| `--treat-tests-as-root` | Treat test methods as entry points |
| `--treat-swift-ui-views-as-root` | Treat SwiftUI Views as entry points |
| `--ignore-swift-ui-property-wrappers` | Ignore SwiftUI property wrappers |
| `--ignore-preview-providers` | Ignore PreviewProvider implementations |
| `--ignore-view-body` | Ignore View body properties |

### `swa duplicates`

Detect code duplication.

```bash
swa duplicates [<path>] [options]
```

| Option | Description |
|--------|-------------|
| `--config <path>` | Path to configuration file |
| `--types <type>` | Clone types: `exact`, `near`, `semantic` (repeatable) |
| `--min-tokens <n>` | Minimum tokens for a clone |
| `--min-similarity <n>` | Minimum similarity (0.0-1.0) |
| `--algorithm <algo>` | Algorithm: `rollingHash`, `suffixArray`, `minHashLSH` |
| `--exclude-paths <glob>` | Paths to exclude (repeatable) |
| `-f, --format <format>` | Output format: `text`, `json`, `xcode` |

## Architecture

```
SwiftStaticAnalysis/
├── SwiftStaticAnalysisCore/     # Core infrastructure
│   ├── Models/                   # Declaration, Reference, Scope
│   ├── Parsing/                  # SwiftFileParser with caching
│   ├── Visitors/                 # AST visitors
│   └── Memory/                   # Zero-copy parsing, arena allocation
├── DuplicationDetector/          # Clone detection
│   ├── Algorithms/               # Suffix Array, MinHash, AST Fingerprint
│   ├── Hashing/                  # LSH, similarity computation
│   └── Models/                   # Clone, CloneGroup
├── UnusedCodeDetector/           # Unused code detection
│   ├── IndexStore/               # IndexStoreDB integration
│   ├── Reachability/             # Graph-based analysis
│   └── Filters/                  # False positive reduction
└── SwiftStaticAnalysisCLI/       # swa command-line tool
```

## Documentation

Full API documentation is available at **[g-cqd.github.io/SwiftStaticAnalysis](https://g-cqd.github.io/SwiftStaticAnalysis/documentation/swiftstaticanalysiscore/)**.

The documentation includes:
- **Getting Started Guide**: Installation and first analysis
- **CLI Reference**: Complete command-line options for the `swa` tool
- **Clone Detection**: Algorithm details and configuration
- **Unused Code Detection**: Detection modes and filtering
- **Ignore Directives**: Reference for suppressing false positives
- **CI Integration**: Setting up automated analysis
- **API Reference**: Complete API documentation for all modules

## Performance

The framework includes several performance optimizations:

- **Memory-Mapped I/O**: Zero-copy file reading for large codebases
- **SoA Token Storage**: Cache-efficient struct-of-arrays layout
- **Arena Allocation**: Reduced allocation overhead for temporary data
- **Parallel Processing**: Concurrent file parsing with configurable limits
- **SIMD-Accelerated Hashing**: Fast MinHash signature computation

## Testing

```bash
# Run all tests
swift test

# Run tests in parallel
swift test --parallel

# Run specific test suite
swift test --filter DuplicationDetectorTests

# Run ignore directive tests
swift test --filter IgnoreDirectiveTests

# Run with verbose output
swift test -v
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Ensure all tests pass (`swift test`)
4. Add tests for new functionality
5. Submit a pull request

## Security

See [SECURITY.md](SECURITY.md) for our security policy.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## License

MIT License - see [LICENSE](LICENSE) for details.
