# SwiftStaticAnalysis

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2015%2B-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![CI](https://github.com/g-cqd/SwiftStaticAnalysis/actions/workflows/ci.yml/badge.svg)](https://github.com/g-cqd/SwiftStaticAnalysis/actions/workflows/ci.yml)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blue.svg)](https://g-cqd.github.io/SwiftStaticAnalysis/documentation/swiftstaticanalysis/)

A high-performance Swift static analysis framework for **code duplication detection**, **unused code elimination**, and **symbol lookup**.

## Features

- **Multi-Algorithm Clone Detection**: Exact (Type-1), near (Type-2), and semantic (Type-3/4) clone detection with parallel MinHash/LSH (enabled by default)
- **IndexStoreDB Integration**: Accurate cross-module unused code detection using compiler index data with improved auto-discovery
- **Reachability Analysis**: Graph-based dead code detection with entry point tracking, parallel edge building, and direction-optimizing BFS
- **Symbol Lookup**: Find symbols by name, qualified name, selector, USR, or regex pattern with rich context extraction
- **Symbol Context**: Extract surrounding code, documentation, signatures, and scope information for matched symbols
- **MCP Server Integration**: Model Context Protocol server (`swa-mcp`) for AI assistant integration
- **Ignore Directives**: Suppress false positives with `// swa:ignore` comments
- **High-Performance Parsing**: Memory-mapped I/O, SoA token storage, and arena allocation
- **Zero-Boilerplate CLI**: Full-featured `swa` command with JSON/text/Xcode output formats
- **Swift 6 Concurrency**: Thread-safe design with `Sendable` conformance throughout
- **Scope-Aware Dataflow Analysis**: Tuple pattern extraction, closure capture handling, and `_`-skip rules
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

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SwiftStaticAnalysis", package: "SwiftStaticAnalysis"),
    ]
)
```

This gives you access to all components including the MCP server. Alternatively, import individual modules:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SwiftStaticAnalysisCore", package: "SwiftStaticAnalysis"),  // Core only
        .product(name: "DuplicationDetector", package: "SwiftStaticAnalysis"),      // Clone detection
        .product(name: "UnusedCodeDetector", package: "SwiftStaticAnalysis"),       // Unused code
        .product(name: "SymbolLookup", package: "SwiftStaticAnalysis"),             // Symbol lookup
        .product(name: "SwiftStaticAnalysisMCP", package: "SwiftStaticAnalysis"),   // MCP server
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

# Enable parallel reachability (large graphs)
swa unused /path/to/project --mode reachability --parallel-mode safe

# Apply sensible filters to reduce false positives
swa unused . --sensible-defaults --exclude-paths "**/Tests/**"

# Look up symbols by name
swa symbol NetworkManager /path/to/project

# Look up with filters
swa symbol "fetch" --kind method --access public /path/to/project

# Find symbol usages
swa symbol "SharedCache.instance" --usages /path/to/project

# Symbol lookup with context (surrounding code)
swa symbol "NetworkManager" --context-lines 3 /path/to/project

# Include documentation and signature
swa symbol "fetchData" --context-documentation --context-signature /path/to/project

# Include all context information
swa symbol "CacheManager" --context-all /path/to/project

# Parallel MinHash/LSH clone detection (large codebases)
swa duplicates /path/to/project --types near --algorithm minHashLSH --parallel-mode safe

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
    "parallelMode": "safe",
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
    "algorithm": "minHashLSH",
    "parallelMode": "safe"
  }
}
```

`parallelMode` controls parallel execution: `none`, `safe`, `maximum`. `safe` matches legacy `--parallel`, while `maximum` enables streaming/backpressure in programmatic pipelines. Legacy `parallel` is still supported but deprecated.

Then run with:

```bash
swa analyze --config .swa.json
```

### Programmatic API

```swift
import SwiftStaticAnalysis
```

#### Duplication Detection

```swift
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
// Use compiler's index data for cross-module accuracy
var config = UnusedCodeConfiguration.indexStore
config.indexStorePath = ".build/debug/index/store"
config.autoBuild = true  // Build if index is stale

let detector = UnusedCodeDetector(configuration: config)
let unused = try await detector.detectUnused(in: swiftFiles)
```

If you omit `indexStorePath`, the detector attempts to auto-discover it in `.build/.../index/store` or Xcode DerivedData.

#### Symbol Lookup

```swift
import SwiftStaticAnalysis

// Create a symbol finder
let finder = SymbolFinder(projectPath: "/path/to/project")

// Find symbols by name
let query = SymbolQuery.name("NetworkManager")
let matches = try await finder.find(query)

for match in matches {
    print("\(match.kind) \(match.name) at \(match.file):\(match.line)")
}

// Find by qualified name
let qualified = SymbolQuery.qualifiedName("APIClient", "shared")
let results = try await finder.find(qualified)

// Find method by selector (with parameter labels)
let selector = SymbolQuery.selector("fetch", labels: ["id", "completion"])
let methods = try await finder.find(selector)

// Find usages of a symbol
if let match = matches.first {
    let usages = try await finder.findUsages(of: match)
    for usage in usages {
        print("  Referenced at \(usage.file):\(usage.line)")
    }
}
```

## Ignore Directives

Suppress false positives directly in your source code using `// swa:ignore` comments.

### Supported Formats

```swift
// swa:ignore                    - Ignore all warnings for this declaration
// swa:ignore-unused             - Ignore unused code warnings
// swa:ignore-unused-cases       - Ignore unused enum case warnings (for exhaustive enums)
// swa:ignore-unused - Reason    - Add description after hyphen separator
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

### Directive Inheritance

Ignore directives are inherited by nested declarations:

```swift
/// Protocol message types. // swa:ignore-unused-cases
enum MessageType {
    case request    // ← Automatically ignored
    case response   // ← Automatically ignored
}

// swa:ignore-unused - SIMD utility operations
public extension SIMDStorage {
    func optimizedSum() -> Float { ... }    // ← Inherits ignore-unused
    func vectorMultiply() -> Float { ... }  // ← Inherits ignore-unused
}
```

## Detection Modes

| Mode | Speed | Accuracy | Use Case |
|------|-------|----------|----------|
| `simple` | Fast | ~70% | Quick scans, large codebases |
| `reachability` | Medium | ~85% | Entry-point based dead code detection |
| `indexStore` | Slow | ~95% | Cross-module, protocol witnesses |

Use `--parallel-mode safe` with `reachability` for direction-optimizing BFS on large graphs.

## Clone Types

| Type | Description | Algorithm |
|------|-------------|-----------|
| **Exact** (Type-1) | Identical code, whitespace-normalized | Suffix Array (SA-IS) |
| **Near** (Type-2) | Renamed variables/literals | MinHash + LSH |
| **Semantic** (Type-3/4) | Functionally equivalent | AST Fingerprinting |

Use `--parallel-mode safe` with `minHashLSH` to enable parallel clone detection.

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

Declarations or parameters named `_` are always skipped as explicitly unused.

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
| `--parallel-mode <mode>` | Parallel mode: `none`, `safe`, `maximum` |
| `--parallel` | Deprecated: use `--parallel-mode` |
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
| `--parallel-mode <mode>` | Parallel mode: `none`, `safe`, `maximum` |
| `--parallel` | Deprecated: use `--parallel-mode` |
| `-f, --format <format>` | Output format: `text`, `json`, `xcode` |

### `swa symbol`

Look up symbols in Swift source files.

```bash
swa symbol <query> [<path>] [options]
```

| Option | Description |
|--------|-------------|
| `--usr` | Treat query as USR (Unified Symbol Resolution) directly |
| `--kind <kind>` | Filter by kind: `function`, `method`, `variable`, `constant`, `class`, `struct`, `enum`, `protocol`, `initializer` (repeatable) |
| `--access <level>` | Filter by access: `private`, `fileprivate`, `internal`, `public`, `open` (repeatable) |
| `--in-type <type>` | Search within type scope |
| `--definition` | Show only definitions |
| `--usages` | Show usages/references |
| `--index-store-path <path>` | Path to index store |
| `--limit <n>` | Maximum results to return |
| `-f, --format <format>` | Output format: `text`, `json`, `xcode` |
| `--context-lines <n>` | Lines of context before and after symbol |
| `--context-before <n>` | Lines of context before symbol |
| `--context-after <n>` | Lines of context after symbol |
| `--context-scope` | Include containing scope information |
| `--context-signature` | Include complete signature |
| `--context-body` | Include declaration body |
| `--context-documentation` | Include documentation comments |
| `--context-all` | Include all context information |

#### Query Patterns

| Pattern | Example | Description |
|---------|---------|-------------|
| Simple name | `NetworkManager` | Find by symbol name |
| Qualified name | `APIClient.shared` | Find member in type |
| Selector | `fetch(id:completion:)` | Find method by signature |
| Regex | `/^handle.*Event$/` | Find by pattern match |
| USR | `s:14NetworkMonitor6sharedACvpZ` | Find by compiler USR |

#### Context Flag Examples

```bash
# Show 3 lines before and after each match
swa symbol "NetworkManager" --context-lines 3 Sources/

# Show documentation and signature
swa symbol "fetchData" --context-documentation --context-signature Sources/

# Show containing scope (class/struct/function)
swa symbol "processItem" --context-scope Sources/

# Include function body
swa symbol "validate" --context-body Sources/

# All context information in JSON format
swa symbol "CacheManager" --context-all --format json Sources/
```

## Architecture

```
Sources/
├── SwiftStaticAnalysis/          # Unified module (re-exports all)
├── SwiftStaticAnalysisCore/      # Core infrastructure
│   ├── Models/                   # Declaration, Reference, Scope
│   ├── Parsing/                  # SwiftFileParser with caching
│   ├── Visitors/                 # AST visitors
│   └── Memory/                   # Zero-copy parsing, arena allocation
├── DuplicationDetector/          # Clone detection
│   ├── Algorithms/               # Suffix Array, MinHash, AST Fingerprint
│   ├── MinHash/                  # LSH, similarity computation
│   └── SuffixArray/              # SA-IS algorithm
├── UnusedCodeDetector/           # Unused code detection
│   ├── IndexStore/               # IndexStoreDB integration
│   ├── Reachability/             # Graph-based analysis
│   └── Filters/                  # False positive reduction
├── SymbolLookup/                 # Symbol resolution
│   ├── Models/                   # SymbolQuery, SymbolMatch
│   ├── Query/                    # QueryParser, USRDecoder
│   ├── Context/                  # SymbolContextExtractor, FileContentCache
│   └── Resolution/               # SymbolFinder, IndexStore/Syntax resolvers
├── SwiftStaticAnalysisMCP/       # MCP server library
│   ├── SWAMCPServer.swift        # MCP server implementation
│   └── CodebaseContext.swift     # Sandboxed codebase access
├── swa/                          # CLI tool
├── swa-mcp/                      # MCP server executable
├── StaticAnalysisBuildPlugin/    # Build-time analysis plugin
└── StaticAnalysisCommandPlugin/  # On-demand analysis plugin
```

## MCP Server

SwiftStaticAnalysis includes a Model Context Protocol (MCP) server that allows AI assistants like Claude to analyze Swift codebases.

### Running the MCP Server

```bash
# Build and run with a default codebase
swift build -c release
.build/release/swa-mcp /path/to/your/project

# Or run without a default (clients must specify codebase_path)
.build/release/swa-mcp
```

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `get_codebase_info` | Get codebase statistics (file count, LOC, size) |
| `list_swift_files` | List Swift files with optional exclusion patterns |
| `detect_unused_code` | Detect unused functions, types, and variables |
| `detect_duplicates` | Find duplicate code patterns |
| `read_file` | Read file contents with line range support |
| `search_symbols` | Search symbols with filters and context extraction |
| `analyze_file` | Full static analysis of a single file |

### Programmatic Usage

```swift
import SwiftStaticAnalysisMCP
import MCP

let server = try SWAMCPServer(codebasePath: "/path/to/codebase")
let transport = StdioTransport()
try await server.start(transport: transport)
```

### Claude Desktop Configuration

Add to your Claude Desktop `claude_desktop_config.json`:

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

## Documentation

Full API documentation is available at **[g-cqd.github.io/SwiftStaticAnalysis](https://g-cqd.github.io/SwiftStaticAnalysis/documentation/swiftstaticanalysis/)**.

The documentation includes:
- **Getting Started Guide**: Installation and first analysis
- **CLI Reference**: Complete command-line options for the `swa` tool
- **Clone Detection**: Algorithm details and configuration
- **Unused Code Detection**: Detection modes and filtering
- **Symbol Lookup**: Query patterns and context extraction
- **MCP Server**: AI assistant integration guide
- **Ignore Directives**: Reference for suppressing false positives
- **CI Integration**: Setting up automated analysis
- **API Reference**: Complete API documentation for all modules

Generate DocC locally (same as CI):

```bash
swift package --allow-writing-to-directory ./docs \
  generate-documentation \
  --target SwiftStaticAnalysis \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path SwiftStaticAnalysis \
  --output-path ./docs
```

## Performance

The framework includes several performance optimizations:

- **Memory-Mapped I/O**: Zero-copy file reading for large codebases
- **SoA Token Storage**: Cache-efficient struct-of-arrays layout
- **Arena Allocation**: Reduced allocation overhead for temporary data
- **Parallel Processing**: Concurrent parsing, reachability edge building, and optional parallel BFS/clone detection via `ParallelMode`
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
