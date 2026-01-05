# Changelog

All notable changes to SwiftStaticAnalysis will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.24] - 2026-01-05

### Added
- Direction-optimizing parallel BFS for reachability analysis (experimental `--parallel`)
- Parallel MinHash/LSH clone detection pipeline with parallel verification and connected components (experimental `--parallel`)
- Scope-aware variable tracking for dataflow analysis, including tuple pattern extraction and closure capture handling
- Parallel edge computation and batch insertion for reachability graph construction

### Changed
- Renamed experimental flags `--xparallel-bfs` and `--xparallel-clones` to unified `--parallel` (config: `parallel`)
- CI pipeline streamlined with code coverage artifacts and simplified build steps

### Fixed
- Improved IndexStore path auto-detection for Xcode DerivedData (normalized names, versioned stores)
- Skip `_` declarations and parameters as explicitly unused
- Format check exclusion handling (glob conversion and path filtering)
- Linter warnings in test files

## [0.0.20] - 2025-12-31

### Changed
- **Umbrella module now exports SymbolLookup**: `import SwiftStaticAnalysis` now provides access to all four modules including SymbolLookup
- **Documentation API references**: SwiftStaticAnalysis.md now lists key types from all modules

### Fixed
- All documentation now consistently uses `import SwiftStaticAnalysis` instead of individual module imports
- Fixed outdated imports in UnusedCodeDetection.md, PerformanceOptimization.md, CloneDetection.md, and SymbolLookup.md
- Fixed `ConcurrentParser` reference to correct `SwiftFileParser` in PerformanceOptimization.md
- Fixed test file formatting (2-space to 4-space indentation in SourceLocationTests.swift)

## [0.0.19] - 2025-12-31

### Added
- **SymbolLookup module**: New module for symbol resolution and lookup in Swift codebases
  - `SymbolFinder` with IndexStore and Syntax-based resolvers
  - `QueryParser` for flexible symbol query patterns (simple names, qualified names, selectors, USRs, regex)
  - `USRDecoder` for Unified Symbol Resolution decoding
  - `SymbolResolver` protocol for dependency injection and testability
- **`swa symbol` CLI command**: Look up symbols by name, qualified name, or USR
  - Filter by kind (`--kind class,struct,function`)
  - Filter by access level (`--access public,internal`)
  - Show definitions only (`--definition`) or usages (`--usages`)
  - Scope to containing type (`--in-type`)
- **CLI integration tests**: 22 tests covering all CLI commands with proper assertions
  - Structured `CLIOutput` with separate stdout/stderr and exit code verification
  - Test fixtures for duplication detection validation

### Fixed
- Force-unwrap violations in `IndexStoreResolver`, `SyntaxResolver`, and `QueryParser`
- Added comprehensive thread safety documentation for `@unchecked Sendable` usages

### Technical Notes
- 120+ SymbolLookup tests covering disambiguation, selectors, and qualified name resolution
- `SymbolFinder` uses `NSLock` (not actor) because `IndexStoreDB` is not `Sendable`

## [0.0.18] - 2025-12-30

### Changed
- Converted `ReachabilityGraph` from `class` with `NSLock` to Swift `actor` for modern concurrency
- All `ReachabilityGraph` methods now use `async`/`await` pattern
- Added comprehensive documentation explaining thread safety design decisions

### Fixed
- Thread safety now enforced at compile-time for reachability analysis (actor isolation)

### Technical Notes
- `IndexBasedDependencyGraph` remains a `class` with `NSLock` because `IndexStoreDB` is not `Sendable`
- Both approaches are documented in-code with rationale for the design choice

## [0.0.17] - 2025-12-30

### Removed
- Debug print statements left in tests (now CI output is clean)
- Unused `tokenIndex` property from `TokenStreamInfo` struct

## [0.0.16] - 2025-12-30

### Added
- Pre-commit hook scripts for automated quality checks (`scripts/pre-commit`, `scripts/install-hooks.sh`)
- Ignore directives for SPM plugin protocol methods (false positive prevention)

### Changed
- CI workflow no longer depends on swiftlint/swiftformat (uses only swift-format from swift-format package)
- Simplified CI pipeline by removing unnecessary Homebrew tool installations

## [0.0.15] - 2025-12-30

### Fixed
- Crash (exit code 133) when file has exactly `minTokens` tokens due to invalid range `1...0` in ExactCloneDetector and NearCloneDetector
- CLI version hardcoded as "0.1.0" instead of actual version
- Auto-exclude common build directories: `.build`, `Build`, `DerivedData`, `.swiftpm`, `Pods`, `Carthage`, `.git`

## [0.0.14] - 2025-12-30

### Added
- Type member inheritance: members of extensions, classes, structs, and protocols now inherit ignore directives from their parent
- CLI Reference documentation article with complete command-line options
- Configuration file section in README with `.swa.json` example
- Full CLI Reference section in README documenting all flags
- Full DocC documentation with API reference and guides
- GitHub Pages documentation hosting at https://g-cqd.github.io/SwiftStaticAnalysis/
- Documentation articles: Getting Started, Clone Detection, Unused Code Detection, Ignore Directives, Performance Optimization, CI Integration
- Pre-built universal binary releases (arm64 + x86_64)
- SHA256 checksums for release verification
- SwiftProjectKit integration for SwiftLint/SwiftFormat build plugins
- IndexStoreDB integration for accurate cross-module unused code detection
- Reachability-based analysis with entry point tracking
- Auto-build support when index store is stale (`--auto-build` flag)
- Hybrid mode combining syntax and index analysis
- Configurable filtering to reduce false positives:
  - `--exclude-imports` - Exclude import statements
  - `--exclude-test-suites` - Exclude test suite declarations
  - `--exclude-deinit` - Exclude deinit methods
  - `--exclude-enum-cases` - Exclude backticked enum cases
  - `--exclude-paths` - Exclude paths matching glob patterns
  - `--sensible-defaults` - Apply all common exclusions
- High-performance parsing optimizations:
  - Memory-mapped I/O for large files
  - SoA (Struct-of-Arrays) token storage
  - Arena allocation for temporary data
  - Parallel file processing with configurable concurrency
- Suffix Array (SA-IS) algorithm for O(n) exact clone detection
- MinHash with LSH for near-clone detection
- AST fingerprinting for semantic clone detection
- GitHub Actions CI/CD workflows
- Comprehensive documentation (README, CONTRIBUTING, SECURITY)

### Changed
- Upgraded to Swift 6.2
- Minimum platform requirements: macOS 15.0+, iOS 18.0+
- Improved test coverage (538 tests across 128 suites)
- Reorganized test files into single-test-suite-per-file structure
- Refactored SemanticCloneDetector to extract common detection logic
- Refactored SuffixArrayCloneDetector to eliminate duplicate clone group building
- **BREAKING**: Replaced SwiftLint and SwiftFormat with official `swift-format` package
- **BREAKING**: Restructured package to follow Apple/Swift.org conventions:
  - CLI target renamed from `SwiftStaticAnalysisCLI` to `swa`
  - Plugins moved from `Plugins/` to `Sources/`
  - Internal types prefixed with underscore (`_DuplicationEngine.swift`)
  - Protocol conformances extracted to separate files (`Type+Protocol.swift`)
  - Modules reorganized into subdirectories (Incremental/, Configuration/, Models/, etc.)
- Updated SwiftProjectKit from 0.0.12 to 0.0.19
- Enhanced swift-format configuration with additional rules:
  - `AvoidRetroactiveConformances`, `NoEmptyLinesOpeningClosingBraces`, `NoPlaygroundLiterals`
- Removed duplicate DocC articles from SwiftStaticAnalysisCore (consolidated in SwiftStaticAnalysis)

### Removed
- Unused `AsyncSemaphore` actor from ConcurrencyConfiguration
- Unused `FileBoundary` struct and related code from SuffixArrayCloneDetector
- Unused `makeLocationConverter` extension from SwiftFileParser

### Fixed
- Ignore directive parsing now correctly handles descriptions after ` - ` separator
- Extension members now properly inherit ignore directives from their parent extension
- Nested type members now inherit ignore directives from all ancestor types
- Silent-pass tests that used `Issue.record()` + return pattern now use `try #require()`
- README version in installation instructions (1.0.0 → 0.1.0)
- CLI `--types` argument syntax in README examples
- CLI argument validation now properly rejects invalid `--types` and `--mode` values
- `--min-tokens` argument now properly validates input (1-10000), preventing crashes
- CLIReference.md typo: "duplications" → "duplicates" command
- CONTRIBUTING.md project structure updated to reflect current layout
- SECURITY.md version corrected from "1.x" to "0.0.x"

## [0.1.0] - Initial Release

### Added
- Core static analysis framework
- SwiftSyntax-based parsing with caching
- Declaration and reference collection
- Basic duplication detection (exact clones)
- Basic unused code detection (simple mode)
- CLI tool (`swa`) with JSON/text/Xcode output formats
- Test fixtures for various scenarios
