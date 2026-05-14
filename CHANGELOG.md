# Changelog

All notable changes to SwiftStaticAnalysis will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-05-15

This release closes the audit (see `AUDIT.md`) across two remediation
sweeps. Sweep 1 (8 commits) fixed the critical-correctness/security
findings; sweep 2 (twelve phases α-ν) extended the work with real
SIMD MinHash, SoA token storage in the duplication hot path, Arena-backed
SA-IS, DenseGraph + ParallelBFS as the reachability default,
AsyncChannel-backed real backpressure, a `swa-bench` perf-regression
gate, mutation testing + Linux CI gates, Span/RawSpan adoption with
`@unchecked Sendable` removed from the memory types, and a Process
environment-allowlist scrubber for IndexStoreDB invocations.

### Breaking changes (since 0.1.x)

- **Module structure**: `Bitmap` / `AtomicBitmap` moved from
  `UnusedCodeDetector` to `SwiftStaticAnalysisCore`. Direct importers
  must now `import SwiftStaticAnalysisCore` (the umbrella module
  re-exports as before).
- **Module carve**: `SwiftStaticAnalysis` no longer transitively pulls
  in `SwiftStaticAnalysisMCP`. Consumers needing MCP must import
  `SwiftStaticAnalysisAll` (umbrella) or `SwiftStaticAnalysisMCP`
  directly. This drops the swift-sdk dependency for library-only users.
- **`SWAConfiguration.format`** changed from `String?` to
  `OutputFormat?`. Decoding rejects unknown strings.
- **CLI enum mirrors removed**: 7 `*Arg` shadow enums in `swa/main.swift`
  deleted. The domain enums (`CloneType`, `DetectionAlgorithm`,
  `DetectionMode`, `Confidence`, `ParallelMode`, `DeclarationKind`,
  `AccessLevel`, `OutputFormat`) now conform to `ExpressibleByArgument`
  directly via `swa/CLIConformances.swift`.
- **`IndexStoreReader.init`** uses typed throws: `throws(IndexStoreError)`.
- **Streaming default**: `ParallelMode.maximum` now means
  "AsyncChannel-backed real backpressure" for streaming verifiers, not
  just "highThroughput preset".

### Sweep 2 highlights

- **Real SIMD MinHash**: `SIMD4<UInt64>` lanes per shingle with
  Mersenne-prime `M_61 = (1<<61)-1` reduction and SplitMix64 coefficient
  mixing. Replaces the scalar unrolled-loop "SIMD" that the previous
  README claimed. Cache schema bumped; old on-disk caches invalidate
  cleanly.
- **SoA token storage**: `TokenSequence` migrated to `SoATokenStorage`.
  Per-window `Array(...)` allocations eliminated from `ShingleGenerator`;
  text-keyed maps replaced with byte-slice keys.
- **Arena-backed SA-IS**: `[Bool] types` replaced with the now-Core
  `Bitmap`. Scratch buffers allocate from `Arena`/`ThreadLocalArena`.
- **DenseGraph + ParallelBFS**: `ReachabilityGraph` projects to
  `DenseGraph` and caches the projection per actor. Auto-selects
  parallel BFS for graphs ≥1000 nodes.
- **AsyncChannel backpressure**: `BackpressuredChannelStream` replaces
  `bufferingNewest(N)` in the streaming verifier path. Slow consumers
  now suspend the producer rather than dropping pairs.
- **swa-bench**: new executable with six scenarios (duplicates exact /
  near / semantic, unused simple / reachability, symbol lookup). CI
  workflow `benchmarks.yml` runs on PRs that touch the hot-path
  modules.
- **Linux CI + mutation testing**: `ci.yml` gains a `swift:6.0-noble`
  matrix leg; `mutation-testing.yml` is now a soft PR gate keyed off
  changed module paths.
- **Process env allowlist**: `ProcessExecutor` scrubs
  `DYLD_INSERT_LIBRARIES` / `SWIFTPM_HOOKS_DIR` etc. before spawning
  indexstore-db invocations. `IndexStoreFallbackManager` and
  `IndexStoreReader.findLibIndexStore` route through it.
- **`MemoryMappedFile.withRawSpan`** + drop `@unchecked Sendable` on
  `MemoryMappedFile`, `FileSlice`, `ArenaTokenStorage`, `AtomicBitmap`.
- **MCP `ReadResource` hardening**: shares `validateForReadFile(...)`
  with `handleReadFile` (extension allowlist + regular-file +
  10 MiB cap).
- **Regex single-match wedge mitigation**: bounded-quantifier
  antipatterns rejected pre-flight; symbol-name lengths capped at
  1024 bytes per occurrence.
- **DocC overhaul**: new `Architecture`, `Performance`, `Security`
  articles describe the actual post-audit codebase.
- **Boundary validation**: `.swa.json` files with bogus enum strings
  (`format: "telepathic"` etc.) are rejected by `ConfigurationLoader`
  with a typed `ConfigurationError.invalidFieldValue`.

### Sweep 1 (audit remediation iteration 1)

### Security (CRITICAL/HIGH)

- **CRITICAL**: MCP path traversal via sibling-path prefix bypass. The
  sandbox check no longer accepts `/tmp/codebase-secret` for a root of
  `/tmp/codebase`. `validatePath` now canonicalises both the candidate
  and the root via `URL.resolvingSymlinksInPath()` and uses a
  separator-aware prefix check.
- **CRITICAL**: MCP symlink escape from inside the sandbox. A
  `Sources/normal.swift -> /etc/passwd` symlink inside the analysed
  codebase is rejected by `validatePath` *and* by `findSwiftFiles`.
- **HIGH**: `handleReadFile` now requires a regular file, an allow-listed
  extension (`.swift/.md/.json/.yml/.yaml/.txt/.toml/.plist`), and caps
  reads at 10 MiB. Line ranges are validated before slicing (no more
  precondition crash when `end_line < start_line`).
- **HIGH**: `handleSearchSymbols` enforces a 256-byte query length cap, a
  2.5 s regex-evaluation budget, and pre-emptive rejection of
  catastrophic-backtracking antipatterns.
- **HIGH**: `MemoryMappedFile.init` requires `S_IFREG`, caps mappings at
  256 MiB by default, and uses `O_NOFOLLOW` on Darwin.

### Fixed

- **Defaults parity**: `swa analyze` and `swa unused` now produce
  identical findings on the same project. Both default
  `--treat-*-as-root` flags to `true`. (Before this commit `analyze`
  defaulted them to `false` while `unused` defaulted them to `true`.)
- **CI exit codes**: every subcommand now exits `2` when findings are
  reported, so `--format xcode` actually gates a build. Validation
  failures exit `64` per ArgumentParser convention. `--report` mode and
  `symbol` (informational) remain at `0`.
- **`--min-tokens` validation**: bounded to `1...10_000` (regression from
  0.0.14 rediscovered by the audit).
- **`--min-similarity` validation**: bounded to `0.0...1.0`.
- **`swa symbol --limit`**: must be `>= 1`.
- **Concurrency contract**: `IndexBasedDependencyGraph.generateReport()`
  now reads the graph under a single `lock.withLock { ... }` scope.
  `detectRoots()` no longer iterates and mutates the same dictionary.
- **MCP schema**: `detect_unused_code` tool now correctly advertises the
  `indexStore` mode in its JSON schema.
- **MCP regex search**: `(try? Regex(q).firstMatch(in: name)) != nil`
  per-declaration is replaced by a single compiled regex shared across
  all matches.
- **MCP path resolution**: tilde expansion now goes through
  `PathUtilities.canonicalize` (no NSString bridge); path equivalence
  uses canonical paths so a hostile alias cannot bypass the cache.
- **`swa-mcp` shutdown**: replaced the unresumable `withCheckedContinuation`
  with `Task.sleep(for: .seconds(.greatestFiniteMagnitude))` so SIGINT
  propagates.

### Performance

- **MemoryMappedFile is now wired through hot paths**: `SwiftFileParser`,
  `_DuplicationEngine.addCodeSnippets`,
  `DuplicationDetector.extractTokenSequences`,
  `MinHashCloneDetector.detect`, `IncrementalDuplicationDetector.detect`,
  and `IgnoreDirectiveScanner.scan` all read source via the new
  `SourceFileReader` helper, which mmaps files ≥ 4 KiB.
- **`findLineRanges` memoised**: the first call performs a full byte
  scan; subsequent `line(_:)` / snippet calls are O(1) lookups.
- **`IndexBasedDependencyGraph` BFS over `DenseGraph`**: replaces the
  `Set<String>/Deque<String>` walk with bit-packed `Bitmap` traversal
  over contiguous integer indices. The dense projection is cached on
  the instance and invalidated on `addEdge`.
- **`IndexStoreAnalyzer.analyzeUsage()` N+1 fix**: a single file-sweep
  via `IndexStoreReader.allOccurrencesByUSR(in:)` replaces the previous
  per-symbol `findOccurrences(ofUSR:)` calls. Drops the dominant cost
  from O(definitions × occurrences) to O(occurrences).
- **Bounded parser caches**: `SwiftFileParser.cache` and
  `ZeroCopyParser.cache` are now LRU-bounded (256 / 64 entries by
  default). This closes the OOM/file-descriptor exhaustion risk for
  long-running MCP sessions.

### Concurrency

- `TaskBackedAsyncStream.makeStream` default buffering is now
  `.bufferingNewest(256)` (was `.unbounded`).
- `ParallelFrontierExpansion.expandParallel` / `expandRangeParallel` call
  `group.cancelAll()` once any worker observes `Task.isCancelled`,
  propagating cancellation to peer tasks.
- Dropped `@unchecked Sendable` from `IndexStoreAnalyzer` and
  `IndexStoreFallbackManager` (all stored state is `let`).
- Removed `ConcurrencyConfiguration.enableParallelProcessing` (dead) and
  `batchSize` (unused). Setting `maxConcurrentFiles: 1` still forces
  serial execution. **Breaking** for direct callers; CLI/MCP unaffected.

### Dependencies

- `swift-atomics` removed in favour of stdlib `Synchronization.Atomic`.
  `AtomicBitmap` migrates to `Atomic<UInt64>` via a small `AtomicWord`
  wrapper (the only consumer of the dependency).
- `modelcontextprotocol/swift-sdk` requirement bumped to `from: "0.12.0"`
  for the upstream `NetworkTransport` race-condition fix.
- `swift-syntax`, `indexstore-db`, `swift-collections`, `swift-algorithms`,
  `swift-async-algorithms`, `swift-format`, `swift-argument-parser`
  updated to their latest minor versions.

### Code quality

- `FNV-1a` is centralised in `Sources/SwiftStaticAnalysisCore/Utilities/FNV1a.swift`.
  Previous inline copies in `ChangeDetector`, `ShingleGenerator`, `LSH`,
  and `MemoryMappedFile.FileSlice.hash` now route through it.
- `ParallelMode.usesStreaming` deleted (zero call sites; the docstring
  promised behaviour that no consumer implemented).
- `DeclarationKindConvertible` protocol deleted (single-conformer
  abstraction with no readers of the protocol type).
- Stale "uses NSLock" doc comments updated to reference
  `Synchronization.Mutex`.
- `ConfigurationLoader.load(from:)` and `loadFromFile(_:)` use typed
  throws (`throws(ConfigurationError)`).

### Added

- `Sources/SwiftStaticAnalysisCore/Utilities/PathUtilities.swift`:
  centralised tilde expansion and canonicalisation.
- `Sources/SwiftStaticAnalysisCore/Memory/SourceFileReader.swift`: single
  entry point for source reads, with mmap-backed `readSource(at:)` and
  `readLines(at:)`.
- `Tests/SwiftStaticAnalysisMCPTests/CodebaseContextTests.swift`: 5 new
  security-regression tests (sibling-path bypass, symlink escape, glob
  metacharacter escaping, tilde handling, findSwiftFiles symlink skip).
- `Tests/CLITests/CLITests.swift`: 5 new CLI tests for the exit-code
  contract, `analyze` ↔ `unused` parity, and numeric-argument validation.

## [0.1.2] - 2026-01-11

### Added
- **MCP Server**: New `swa-mcp` tool for Model Context Protocol integration
  - Dynamic `codebase_path` support for all tools
  - Symbol context extraction capabilities
- **Compact Output**: New LLM-optimized text output format for CLI results

### Fixed
- **IndexStore**: Correct access level extraction from source code for IndexStore results

### Changed
- Documentation cleanup
- Updated version sync targets to include `swa-mcp`

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
