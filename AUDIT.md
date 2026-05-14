# SwiftStaticAnalysis — Comprehensive Codebase Audit

**Audit date:** 2026-05-14
**Audited commit:** `6914899` (snapshot of working tree)
**Auditor:** Multi-agent review (architecture, performance, concurrency, security, quality, feature-gap, open-source-opportunities, API/SOTA)
**Scope:** All `Sources/`, `Tests/`, `Package.swift`, `Package.resolved`, `.githooks/`, `.github/`, `SECURITY.md`, `README.md`, `CHANGELOG.md`

---

## Executive Summary

SwiftStaticAnalysis is a Swift-6.2/macOS-15-targeted static-analysis framework with a CLI (`swa`) and an MCP server (`swa-mcp`) for AI-assistant integration. It claims clone detection (Type-1/2/3-4), unused-code detection (simple/reachability/indexStore), and symbol lookup, with extensive performance plumbing (mmap, SoA tokens, arena allocator, parallel BFS, SIMD MinHash).

**Headline findings:**

1. **The performance story is largely fictional.** `MemoryMappedFile`, `ZeroCopyParser`, `Arena`, and `SoATokenStorage` exist as well-implemented infrastructure but are **not wired into any production hot path**. Hot paths run `String(contentsOfFile:)` → AoS `[TokenInfo]` with `String text` → `[String: Int]` interning → string-keyed BFS. The "SIMD-accelerated MinHash" routine imports `simd` but contains **zero SIMD types** — it is unrolled scalar arithmetic. (See §4.)
2. **The MCP server has two CRITICAL path-traversal vulnerabilities.** Both reduce to `hasPrefix(rootPath)` without a separator boundary and missing `resolvingSymlinksInPath` resolution. A hostile codebase can exfiltrate `~/.ssh/`, `~/.aws/`, browser cookies, etc. The "Safe to run on untrusted codebases" claim in `SECURITY.md` is incorrect. (See §6.)
3. **`swa analyze` and `swa unused` produce different results on the same project without any flags.** The two subcommands default `--treat-*-as-root` flags inconsistently (`Unused` → `true`, `Analyze` → `false`). This is a correctness bug. (See §3.)
4. **The CLI never returns a non-zero exit code on findings.** CI integration is documented but `swa` always exits 0 on success regardless of finding count. Build/Command plugins consequently cannot gate builds. (See §3.)
5. **`ParallelMode.maximum` is functionally identical to `.safe`.** The README claims `maximum` "enables backpressure and memory-bounded processing"; in practice both modes flatten to the same `isParallel: Bool`. (See §3.)
6. **Long-running MCP sessions will OOM.** `SwiftFileParser.cache` and `ZeroCopyParser.cache` are unbounded `[String: ...]` dictionaries holding entire SwiftSyntax trees / mmap'd file descriptors. (See §4.)

The codebase has notable strengths: Swift 6 language mode is on everywhere, `Sendable` coverage is wide, `Synchronization.Mutex` has already displaced `NSLock`, SA-IS and Kasai's algorithm are correctly implemented, ignore directives and their inheritance are correctly wired, and the IndexStore auto-discovery in `.build/...` and Xcode DerivedData is solid. The architecture is sound at the macro level (clean module boundaries except one inverted dependency); most issues are localized.

**Severity counts across all dimensions:**

| Severity | Count |
|----------|-------|
| CRITICAL | 2 (path traversal, symlink escape) |
| BLOCKER | 3 (perf claims fictional: mmap, arena, SIMD-MinHash) |
| HIGH    | 27 |
| MEDIUM  | 41 |
| LOW     | 22 |
| INFO    | 10 |

---

## Methodology

Eight focused investigations ran in parallel against a frozen snapshot. Each produced file:line-cited findings. The original detailed reports are in `.tmp/audit/01-08-*.md`. This document is the synthesis.

| # | Dimension | Source |
|---|-----------|--------|
| 1 | Architecture & module design | `.tmp/audit/01-architecture.md` |
| 2 | Apple/Swift open source opportunities | `.tmp/audit/02-opensource.md` |
| 3 | Swift 6 concurrency correctness | `.tmp/audit/03-concurrency.md` |
| 4 | Performance: claims vs reality | `.tmp/audit/04-performance.md` |
| 5 | Code quality, complexity, consistency | `.tmp/audit/05-quality.md` |
| 6 | Feature-vs-implementation gap | `.tmp/audit/06-feature-gap.md` |
| 7 | Security posture | `.tmp/audit/07-security.md` |
| 8 | API misuse & SOTA gap | `.tmp/audit/08-api-sota.md` |

---

## 1. Architecture & Module Design

### Top findings

- **HIGH — Inverted dependency.** `DuplicationDetector` imports `UnusedCodeDetector` solely for `AtomicBitmap` / `Bitmap` (`Package.swift:104`, `ParallelConnectedComponents.swift:9`). Clone detection should not depend on the dead-code module. **Fix:** extract `BitUtilities` (or move `Bitmap` into `SwiftStaticAnalysisCore`).
- **HIGH — MCP server duplicates CLI config-merging.** `SWAMCPServer.swift:535–590` re-implements the same flag→config translation as `swa/main.swift:710–732`. Three subcommands plus MCP = four copies of the same logic. **Fix:** move `buildUnusedConfig`/`buildDuplicationConfig` into `SwiftStaticAnalysisCore` and call them from both CLI and MCP.
- **HIGH — No protocol seams for dependency injection.** Detectors hard-code their internal collaborators (`DuplicationDetector` instantiates `DuplicationEngine` + `SwiftFileParser` internally at `DuplicationDetector.swift:212-213`). Tests can't mock parsers or graphs; they must use real file I/O. **Fix:** introduce thin `FileParser` / `DependencyExtractor` protocols.
- **HIGH — Public API surface bloat.** ~150+ public types re-exported through the umbrella module. `DuplicationDetector/Parallel/*` exposes 43 public types consumed only within its own module. **Fix:** mark ~40% of public types `internal` or `package`.
- **MEDIUM — `swa/main.swift` is 1,231 lines** with no engine-layer abstraction between CLI parsing and detector invocation. The `Unused.run()` method has a `// swiftlint:disable:next function_body_length` suppression.
- **MEDIUM — Umbrella forces MCP dependency on all umbrella clients** (`Package.swift:208`). Importing `SwiftStaticAnalysis` pulls in `modelcontextprotocol/swift-sdk` for users who just want the detectors.

### Architecture is **functionally sound** but evolved from CLI-first design rather than library-first design. Refactor toward `CLIArguments → AnalysisRequest → AnalysisEngine → Detector APIs` before 1.0.

---

## 2. Performance: Claims vs Reality (BLOCKER cluster)

### BLOCKER — Memory-Mapped I/O is dead code

`MemoryMappedFile` and `ZeroCopyParser` are correctly implemented but are **not consumed anywhere in production**. `grep -r ZeroCopyParser Sources/` returns hits only inside their own files. Production paths call `String(contentsOfFile:encoding:)`:

- `_DuplicationEngine.swift:73`
- `DuplicationDetector.swift:304`
- `MinHashCloneDetector.swift:179`
- `IncrementalDuplicationDetector.swift:118`
- `SwiftFileParser.swift:136`
- `CodebaseContext.swift:138`
- `SWAMCPServer.swift:674,926`
- `SymbolLookup/Context/{AccessLevelExtractor,SymbolContextExtractor,FileContentCache}.swift`

**The README's "Memory-Mapped I/O (zero-copy)" claim is false in practice.** Even when the mmap path is taken (`ZeroCopyParser.parseMemoryMapped`), the next line is `mapped.readAsString() ?? ""` — a UTF-8-validating copy into a `String`.

### BLOCKER — Arena allocator is unused outside its own tests

`grep -r 'Arena(' Sources/ | grep -v Arena.swift` returns zero hits. The 400-LOC bump allocator is exercised only by `Tests/SwiftStaticAnalysisCoreTests/MemoryTests.swift`. The README's "Arena Allocation" claim refers to unused infrastructure.

### BLOCKER — "SIMD-accelerated MinHash" contains zero SIMD types

`MinHash.swift:9` imports `simd`; `computeSignatureSIMD` (line 147-190) is hand-unrolled scalar `UInt64` arithmetic. No `SIMD4<UInt64>`, no `vDSP`, no `Accelerate`. The modulo-by-large-prime on lines 170-173 is a 64-bit integer divide that no vector pipeline accelerates. **Fix:** use Mersenne prime `(1 << 61) - 1` so modulo becomes `(x & M) + (x >> 61)`, pack coefficients into `SIMD4<UInt64>`, or retract the claim.

### HIGH — SoA token storage is real but unused

Hot paths use AoS `[TokenInfo]` with `String text` per token (`TokenSequenceVisitor.swift:105-125`), then `sequence.tokens.map(\.text)` (`ShingleGenerator.swift:134-135, 172-173`) allocates a parallel `[String]`. The SoA layout in `SoATokenStorage.swift:103-115` exists but is only populated by `ZeroCopyParser` — which no one calls.

### HIGH — `ReachabilityGraph.computeReachable()` and `IndexBasedDependencyGraph.computeReachableLocked()` are sequential string-keyed BFS

`Set<String> visited` / `Deque<String> queue` walking USRs. For 10k+ symbols this is the hottest path in the codebase and uses **none** of the existing `DenseGraph` + `ParallelBFS` infrastructure. The Beamer α/β direction-optimizing path (`ParallelBFS.swift:121-198`) is correct but only reachable via opt-in `--parallel` flag.

### HIGH — Unbounded caches will OOM long-running MCP sessions

`SwiftFileParser.cache` (`SwiftFileParser.swift:124`) and `ZeroCopyParser.cache` (`ZeroCopyParser.swift:215`) are `[String: ...]` dictionaries with no eviction. Each entry retains a full `SourceFileSyntax` (and in the mmap case, an open file descriptor). On macOS the default `ulimit -n` is 256 — a long-running session opening >256 files will fail unrecoverably.

### HIGH — `ShingleGenerator` allocates per-window arrays

`Array(tokens[i..<(i+blockSize)])` and `Array(kinds[i..<(i+blockSize)])` at `ShingleGenerator.swift:178-179` allocate two arrays of 50 elements per shingle stride. For a 50k-token file with stride 25 = 4k allocations per file. Replace with `ArraySlice` and accept `Collection`.

### HIGH — SA-IS memory budget is brutal

For a 100 MB token stream, `text: [Int]` (240 MB), `types: [Bool]` (30 MB), `sa: [Int]` (240 MB), plus reduced strings = >700 MB of Int arrays alone. **Fix:** generic `T: FixedWidthInteger` defaulting to `UInt32`; replace `[Bool]` types with `Bitmap`.

### Top 3 perf actions

1. **Wire `MemoryMappedFile` + `SoATokenStorage` into `SwiftFileParser` and `TokenSequenceExtractor`.** Single biggest unlocked win; makes the README accurate.
2. **Replace string-keyed BFS in `IndexBasedDependencyGraph` and `ReachabilityGraph` with `DenseGraph + ParallelBFS`.** Default mode (indexStore) finally uses the parallel infrastructure.
3. **Delete `Arena` or wire it into SA-IS scratch arrays.** Halves SA-IS memory.

Plus: bound the caches, fix MinHash actually using SIMD, or retract the claims.

---

## 3. Feature Gap & Correctness

### BROKEN — `Analyze` ≠ `Unused`

`main.swift:320-323` (`Unused.run()`) defaults `treatPublicAsRoot`, `treatObjcAsRoot`, `treatTestsAsRoot`, `treatSwiftUIViewsAsRoot` to **`true`**. `main.swift:719-732` (`buildUnusedConfig` used by `Analyze`) defaults them to **`false`**. So `swa unused .` and `swa analyze .` produce **different findings on the same project** without any flag changes.

### MISSING — No exit codes for CI gating

Zero references to `ExitCode`, `exit(_:)`, or finding-count-aware throws in `swa/main.swift`. All four `run()` methods return normally regardless of result count. **`--format xcode` and `swa analyze . --format json > report.json` are documented for CI but cannot actually fail a build.** Build/Command plugins inherit this — they shell out to `swa` whose exit code is always 0.

### MISSING — `--min-tokens` argument validation regression

CHANGELOG 0.0.14 says: *"`--min-tokens` argument now properly validates input (1-10000), preventing crashes"*. Current declaration (`main.swift:138-139`) is bare `@Option var minTokens: Int?` with no `transform:` or guard. Values like `0` or `-1` silently propagate; detectors guard against them so no crash, but the validation regressed and produces silent no-op runs.

### OVER-PROMISED — `ParallelMode.maximum`

`ParallelMode.swift:38` claims `maximum` "enables backpressure and memory-bounded processing." Reality: CLI flattens both `.safe` and `.maximum` to `isParallel: Bool` and feeds `useParallelClones`/`useParallelBFS`. No consumer switches on `.safe` vs `.maximum`. `usesStreaming` (line 63) has **zero call sites**. `.maximum` is an alias of `.safe`.

### GAP — MCP `detect_unused_code` schema omits `indexStore`

`SWAMCPServer.swift:178` enum lists only `simple` and `reachability`. The handler at line 540 accepts `indexStore` if passed, but clients consulting the schema would never know.

### VERIFIED & solid (positive observations)

- All 6 ignore-directive formats parse correctly (`DeclarationCollector.swift:697-759`).
- Directive inheritance through nested types works (`DeclarationCollector.swift:143-322`).
- The CHANGELOG'd `1...0` SA-IS crash is gated (`ExactCloneDetector.swift:194-196`, `NearCloneDetector.swift:140-142`).
- IndexStore auto-discovery handles `.build/{debug,release}/index/store/v5|v6/...` and URL-encoded Xcode DerivedData.
- The IndexStore refactors in `IndexStoreAnalyzer.swift` (commit `bbbf4bb`) are clear improvements: collapsed scattered role-check patterns into shared `isDefinitionLike`/`indicatesUsage`, fixed `isTestSymbol` over-flagging files merely containing "Test" in their path.
- Compact LLM-optimized format is wired through both CLI and MCP.

---

## 4. Security (CRITICAL cluster)

### CRITICAL #1 — Sibling-path bypass via `hasPrefix` (CWE-22)

`CodebaseContext.swift:51`:
```swift
guard resolvedPath.hasPrefix(rootPath) || resolvedPath == rootPath else { ... }
```

With `rootPath = "/tmp/codebase"`, the path `/tmp/codebase-secret/file.txt` passes the check. There is no separator boundary. Identical issue at `SWAMCPServer.swift:66` (`expandedPath.hasPrefix("/")`).

### CRITICAL #2 — Symlink escape (CWE-59)

`validatePath` uses `URL.standardized` which normalises `.`/`..` but does NOT resolve symlinks. A hostile repo shipping `Sources/normal.swift -> /Users/victim/.aws/credentials` passes validation; `list_swift_files` returns it; `read_file` exfiltrates the contents.

### HIGH — `read_file` reads anything

No size limit, no `isRegularFile` check, no extension allowlist. Will block on FIFOs, exhaust memory on `/dev/zero`, and `lines[start..<end]` with `endLine < startLine` triggers a Swift precondition crash. (`SWAMCPServer.swift:665-692`)

### HIGH — Regex catastrophic backtracking

`search_symbols` with `use_regex=true` runs user input through `Regex(query).firstMatch(in:)` for every declaration **without timeout** (`SWAMCPServer.swift:707-719`). A pattern like `(a+a+)+a+!` against any name longer than ~20 chars hangs the actor.

### HIGH — Auto-build code execution surface (latent)

`/usr/bin/swift build` in attacker-controlled `currentDirectoryURL` (`IndexStoreFallback.swift:194-219`). SPM parses `Package.swift` as Swift source — arbitrary code at manifest-load time. Currently not exposed via MCP, but easy to regress. `xcrun --find swift` (`IndexStoreReader.swift:282`) inherits `DEVELOPER_DIR` / `TOOLCHAINS` — controllable dylib load path.

### MEDIUM — Glob → regex injection

`CodebaseContext.swift:106-121` escapes `.` but not `+`, `(`, `[`, `?`, `^`, `$`, `|`, `\`. User-supplied `exclude_patterns` can inject regex behaviour.

### MEDIUM — `Process` inherits parent environment unfiltered

Five `Process` invocations (`IndexStoreFallback.swift`, `IndexStoreReader.swift`, `StaticAnalysisCommandPlugin/Plugin.swift`) never set `environment`. `DEVELOPER_DIR`, `DYLD_INSERT_LIBRARIES`, `SWIFTPM_HOOKS_DIR` flow through.

### MEDIUM — Dependency supply chain

- `indexstore-db` pinned by revision, not version (`Package.swift:75`, `Package.resolved:14-22`).
- Transitive `swift-lmdb` tracks `main` branch (`Package.resolved:103-110`).
- `mattt/eventsource` (transitive via `swift-sdk`) is a small personal repo without org governance.
- `swift-sdk` is pre-1.0 (resolved 0.10.2) — no semver guarantees yet.

### LOW — `SECURITY.md`

Directs reports to **public GitHub Issues** — opposite of responsible disclosure. Supported-versions table says `0.0.x` while current version is `0.1.4`. The "Safe to run on untrusted codebases" claim is contradicted by every finding above. Enable GitHub's private vulnerability reporting.

### Top 4 security actions before 0.1.5

1. Replace `hasPrefix(rootPath)` with canonical-prefix-with-separator check, after `resolvingSymlinksInPath` on **both** sides.
2. In `handleReadFile`: stat the file, reject non-regular and oversized files, validate line range bounds.
3. Add per-call regex evaluation timeout in `search_symbols` and a complexity heuristic before compiling.
4. Enable GitHub private vulnerability reporting; rewrite `SECURITY.md`; remove the "safe on untrusted codebases" claim until the symlink/path fixes land.

---

## 5. Swift 6 Concurrency

The codebase already uses Swift 6 language mode and `Synchronization.Mutex`. Most `@unchecked Sendable` usages are documented and justified. The issues below are residual.

### HIGH — `IndexBasedDependencyGraph.generateReport()` reads outside the lock

`IndexBasedDependencyGraph.swift:639-668` accesses `nodes.values`, `roots`, and `roots.count` directly without `lock.withLock { ... }` while the safety contract claimed at `:154-153` says every access goes through the lock. **Fix:** wrap the whole report assembly in a single `withLock`.

### HIGH — `ConcurrencyConfiguration.enableParallelProcessing` is dead

Declared at `ConcurrencyConfiguration.swift:60`, set by `.serial` preset, **never read**. The configuration silently lies. Either wire it or delete the field.

### HIGH — `TaskBackedAsyncStream` defaults to `.unbounded`

`TaskBackedAsyncStream.swift:18`. The `ParallelMode.maximum` "memory-bounded" claim depends on call sites passing `.bufferingNewest`, which most do — but `.bufferingNewest` is **buffer + drop**, not backpressure. A slow consumer on a huge codebase silently drops clone groups. Use `AsyncChannel` from `swift-async-algorithms` for real suspending backpressure.

### HIGH — Iterate-while-mutating in `IndexBasedDependencyGraph.detectRoots()`

`IndexBasedDependencyGraph.swift:477-487`: iterates `for (usr, node) in nodes` and mutates `nodes[usr] = mutableNode` inside the loop. Undefined behaviour on COW dictionaries. **Fix:** collect-then-mutate.

### MEDIUM — Cancellation isn't propagated in `ParallelFrontierExpansion`

The outer task may be cancelled but `withTaskGroup` doesn't call `group.cancelAll()`, so peer tasks finish their full chunk before yielding. (`ParallelFrontierExpansion.swift:14-95`)

### MEDIUM — Actor congestion in `ReachabilityGraph`

Long-running BFS (`computeReachable()`, `exportDenseGraph()`) blocks every other actor request for hundreds of ms on 50K+ node graphs. Yield periodically.

### LOW — Stale "uses NSLock" docs

Comments in `IndexBasedDependencyGraph.swift:138-153`, `ReachabilityGraph.swift:174`, `SymbolFinder.swift:32-37`, and the README claim NSLock but the code already uses `Synchronization.Mutex`.

### LOW — `swa-mcp/main.swift:79` uses an unresumable `withCheckedContinuation`

Replace with `try await Task.sleep(for: .seconds(.infinity))` so SIGTERM/`Task.cancel()` propagate.

### LOW — `@unchecked Sendable` can be dropped on three types

`IndexStoreAnalyzer` (`IndexStoreAnalyzer.swift:64`), `IndexStoreFallbackManager` (`IndexStoreFallback.swift:132`), `AtomicBitmap` (`Bitmap.swift:28`) — all are immutable-after-init with `Sendable` payload types; they could be plain `Sendable`.

---

## 6. API Misuse & SOTA Gap

### HIGH — Typed throws barely adopted

Only 4 functions use `throws(MyError)` despite each module owning a single focused error enum. `ConfigurationLoader.load(from:)`, `IndexStoreReader.init(...)`, all `CodebaseContext` factories are obvious wins. The work is already done — the error types exist and are distinct.

### HIGH — `Span<T>` / `RawSpan` / `MutableSpan` not adopted

`SoATokenStorage` (`:326`), `MemoryMappedFile.asBytes()` (`:318`), `subscript(range:)` (`:147`), `ZeroCopyParser.computeLineRanges` (`:337`) all return raw `UnsafeBufferPointer` or allocate full-byte arrays. Three of the `@unchecked Sendable` annotations disappear once these become borrowed `Span` projections.

### HIGH — `@OptionGroup` / `validate()` unused in `swift-argument-parser`

Zero `@OptionGroup` usage. Four subcommands re-declare `paths`, `config`, `excludePaths`, `parallel`, `parallelMode`, `format`. Zero `validate()` overrides — `Duplicates.minSimilarity` (`main.swift:142`) is `Double?` documented as `0.0–1.0` but unchecked.

### HIGH — IndexStoreDB role pre-filtering missed

`IndexStoreReader.swift:345, 408` pass `.all` to `forEachSymbolOccurrence(byUSR:roles:)` then post-filter via `convertRoles`. The IndexStoreDB B-tree can do the prune itself — pass exact roles.

### HIGH — N+1 in `IndexStoreAnalyzer.analyzeUsage`

`IndexStoreAnalyzer.swift:76-108`: for each definition calls `reader.findOccurrences(ofUSR: usr)` — one round-trip per symbol × thousands of symbols. Build an inverse map (USR → [occurrences]) in a single sweep over `forEachCanonicalSymbolOccurrence`. **Single biggest performance fix in the audit after the unused infrastructure wiring.**

### HIGH — `NSString` survivors

`swa-mcp/main.swift:50`, `SWAMCPServer.swift:64`, `CodebaseContext.swift:19` use `NSString(string:).expandingTildeInPath`. Use `(path as NSString)` bridge form or `FileManager.homeDirectoryForCurrentUser` directly.

### MEDIUM — `NSRegularExpression` survivor

`CodebaseContext.swift:115`. Replace with Swift `Regex` literal.

### MEDIUM — `InlineArray<128, UInt64>` for MinHash signatures

Fixed-size payload, perfect candidate. (`MinHash.swift:26`)

### MEDIUM — Print to stdout in CLI

40+ `print(...)` calls; status messages (`"Analyzing 42 Swift files..."` at `main.swift:61`) go to stdout, polluting `--format json` redirected output. The MCP server already uses `fputs(..., stderr)` correctly.

### MEDIUM — String hot-path waste

`String.components(separatedBy: "\n")` called 18 times for newline splitting; `String.trimmingCharacters` 20+ times on `node.description` (use `node.trimmedDescription`).

### INFO — Wins already in place

- No `try!`, no force unwraps in `Sources/`.
- No `@Observable` / `ObservableObject` (correctly: it's a library).
- No `Task.detached`.
- All `Codable` types use synthesized conformance.
- Existential-vs-generic refactor appears complete (`[any Protocol]` essentially absent from hot paths).

---

## 7. Apple/Swift Open-Source Opportunities

### Positive observations

- `swift-collections.Deque` used in BFS queues (`IndexBasedDependencyGraph.swift:226`, `MinHashCloneDetector.swift:405`).
- `swift-algorithms` chunks/combinations/uniqued/chain used across parallel dispatch.
- `Synchronization.Mutex` already replaces NSLock in three locations.
- `OSLog.Logger` correctly powers `AnalysisLogger`.
- `SourceLocationConverter` is cached per file (no repeated construction per node).
- IndexStoreDB high-level callback APIs used throughout.

### Recommended adoptions

- **HIGH — Replace `ManagedAtomic<UInt64>` with stdlib `Atomic<UInt64>`** (Swift 6.0+, deployment floor satisfied). Eliminates `swift-atomics` dependency entirely; `AtomicBitmap` migration is mechanical. (`Bitmap.swift:5, 36, 161`)
- **HIGH — Replace non-atomic `Bitmap` with `BitArray` from swift-collections.** Deletes 123 lines of bit-manipulation code. (`Bitmap.swift:170-293`)
- **HIGH — Migrate `Process` to `swift-subprocess`** for `IndexStoreFallback.swift` and `IndexStoreReader.swift`. Gives `async`/`await`, structured cancellation, no `Pipe`/`FileHandle` boilerplate. Plugin targets cannot use it (sandboxed) — leave those as `Process`.
- **MEDIUM — Consolidate two glob → regex implementations.** `CodebaseContext.matchesGlobPattern` (`CodebaseContext.swift:107-121`) and `UnusedCodeFilter.globToRegexPattern` are duplicates; neither uses `RegexCache`.
- **MEDIUM — Use `MemoryMappedFile` for `ChangeDetector.computeState` hashing.** Currently `FileManager.contents(atPath:)` allocates a full `Data`. (`ChangeDetector.swift:253-272`)
- **MEDIUM — Deduplicate FNV-1a** between `ChangeDetector.swift:349-401` and `MemoryMappedFile.swift:348-357`.
- **LOW — `RegexCache` "first-key eviction" is not LRU.** `Dictionary.keys.first` returns arbitrary hash order. Use `OrderedDictionary` from swift-collections. (`RegexCache.swift:51-56`)
- **LOW — `StreamingVerifier` doc claims `AsyncChannel`** but uses `TaskBackedAsyncStream`. Either update the doc or use a real `AsyncChannel`. (`ParallelVerification.swift:242`)

---

## 8. Code Quality, Complexity, Consistency

### HIGH — 28 separate `*Configuration` structs with no shared ancestor

Two uncoordinated layers:
- **JSON/CLI layer** uses `String?` for `format`, `mode`, `algorithm`, `minConfidence` — a typo is undetected until runtime.
- **Detector layer** uses proper enums.

Translation is done ad-hoc in `buildUnusedConfig`/`buildDuplicationConfig` and re-done in MCP and re-done in `applyUnusedFilters`. (`SWAConfiguration.swift:59,137,143,256`)

### HIGH — `DuplicationDetector → UnusedCodeDetector` inverted dependency

Repeats the architectural finding from §1.

### MEDIUM — `*Arg` enum mirror anti-pattern

`ConfidenceArg`, `DetectionModeArg`, `CloneTypeArg`, `AlgorithmArg`, `ParallelModeArg` (`main.swift:844-937`) each mirror an existing domain enum with identical cases and a `toX` switch. Delete all five; conform domain enums (already `String`-rawvalued) to `ExpressibleByArgument` directly. -150 lines, zero behavior change.

### MEDIUM — Deprecated `--parallel` flag migration is messy

`parallel: Bool?` (deprecated) and `parallelMode: ParallelMode?` are peer fields with `resolvedParallelMode` to bridge them, **but** `buildUnusedConfig` (`main.swift:731`) reads `config?.parallel ?? false` directly instead of going through `resolvedParallelMode`. Result: `Analyze` ignores `parallelMode` from `.swa.json`, `Unused` / `Duplicates` honor it.

### MEDIUM — Config merge duplicated three ways

`Unused.run()` has 25 `effective*` locals; `Duplicates.run()` repeats the pattern (`main.swift:163-196`); MCP server has its own copy.

### MEDIUM — Public surface bloat in implementation modules

`LCPArray`, `SuffixArray`, `DetectedRepeat` are `public` but consumed only within `DuplicationDetector`. ~40 parallel sub-types similarly.

### LOW — Sentinel values

`SuffixArrayCloneDetector.swift:184-185` uses `line: -1, column: -1` for "unknown". Replace with `Int?` or `SourceLocation.unknown`.

### LOW — Terminology fragmentation

`SymbolMatch` vs `SymbolOccurrence` vs `IndexedOccurrence` — three near-identical types in three modules.

### LOW — Tests added in working tree

- `Tests/SwiftStaticAnalysisTests/SwiftStaticAnalysisTests.swift` is a 26-line "re-export smoke test" that tests no behavior. Useful as API-surface guard, mislabeled as test suite.
- `Tests/SwiftStaticAnalysisMCPTests/SWAMCPCommandTests.swift` hardcodes `.build/debug/swa-mcp` (breaks in release CI) and uses `process.waitUntilExit()` without a timeout (will hang the test suite if the binary deadlocks).

---

## 9. Prioritised Remediation Plan

### Block 0.1.5 release (CRITICAL/HIGH security + correctness)

1. **Path-traversal: canonical prefix + symlink resolution** (`CodebaseContext.swift:51`, `SWAMCPServer.swift:66`).
2. **`read_file` hardening**: stat, size cap, isRegularFile, extension allowlist, line-range validation.
3. **Regex timeout in `search_symbols`** + complexity heuristic.
4. **Fix `Analyze` vs `Unused` default inconsistency**: unify `--treat-*-as-root` defaults across subcommands.
5. **Re-add `--min-tokens` runtime validation** (1-10000).
6. **Add non-zero exit code on findings** so CI gating actually works.
7. **Enable GitHub private vulnerability reporting**; rewrite `SECURITY.md` (remove "safe on untrusted codebases", update version table).

### Next milestone (BLOCKER perf claims + HIGH concurrency)

8. **Wire `MemoryMappedFile` + `SoATokenStorage` into `SwiftFileParser` and `TokenSequenceExtractor`** — or delete the unused modules and retract the README claims.
9. **Replace string-keyed BFS in `IndexBasedDependencyGraph` and `ReachabilityGraph`** with `DenseGraph + ParallelBFS`.
10. **Bound `SwiftFileParser.cache` and `ZeroCopyParser.cache`** (LRU or `NSCache`) to prevent OOM in long-running MCP sessions.
11. **MinHash: implement true SIMD with `SIMD4<UInt64>` and Mersenne prime modulo**, or retract the SIMD claim.
12. **Fix `IndexBasedDependencyGraph` lock contract** in `generateReport()` and `detectRoots()`.
13. **Either implement or delete `ConcurrencyConfiguration.enableParallelProcessing`**.
14. **Decide `ParallelMode.maximum`**: real `AsyncChannel`-backed streaming, or collapse to alias of `.safe` and update docs.

### Architecture / cleanup milestone

15. **Move `AtomicBitmap` + `Bitmap` to `SwiftStaticAnalysisCore`** (or new `BitUtilities`) — eliminates `DuplicationDetector → UnusedCodeDetector` inverted dependency.
16. **Migrate `ManagedAtomic<UInt64>` → stdlib `Atomic<UInt64>`** — remove `swift-atomics` dependency.
17. **Replace non-atomic `Bitmap` with `BitArray` from swift-collections** — delete 123 LOC.
18. **Migrate `Process` to `swift-subprocess`** (non-plugin targets only).
19. **Consolidate config-merging** into `SwiftStaticAnalysisCore` and call from CLI + MCP.
20. **`@OptionGroup` for CLI shared options** + `validate()` on numeric ranges.
21. **Delete `*Arg` enum mirrors** — conform domain enums to `ExpressibleByArgument` directly.

### Polish

22. Typed throws across `ConfigurationLoader`, `IndexStoreReader.init`, all `CodebaseContext` factories.
23. `Span<T>` / `RawSpan` adoption in `Memory/` types — eliminates three `@unchecked Sendable` annotations.
24. Push role-filtering into IndexStoreDB queries (eliminates `.all` + post-filter pattern).
25. Fix N+1 in `IndexStoreAnalyzer.analyzeUsage` — build inverse USR map in single sweep.
26. `node.trimmedDescription` everywhere (SwiftSyntax 510+ API).
27. Update stale "uses NSLock" doc-comments; `try await Task.sleep(for: .seconds(.infinity))` in `swa-mcp/main.swift`.
28. Diagnostic `print()` in CLI → `FileHandle.standardError.write`.
29. Mark `LCPArray`, `SuffixArray`, `DuplicationDetector/Parallel/*` types `internal`.
30. Pin `indexstore-db` to a tagged release; vendor or fork `mattt/eventsource`.

---

## 10. Closing Assessment

SwiftStaticAnalysis is technically ambitious, demonstrates real algorithmic competence (SA-IS, Beamer α/β BFS, MinHash + banded LSH, AST fingerprinting), and adopts modern Swift idioms (Swift 6 language mode, `Synchronization.Mutex`, structured concurrency, `Sendable` discipline). The major refactors visible in recent commits (Mutex migration, IndexStore access-level extraction, `Arena` noncopyable, treat-*-as-root flag wiring) are clear improvements.

But the **gap between marketing and engineering reality is substantial**:

- The README/CHANGELOG sells performance features (mmap, SoA, arena, SIMD-MinHash, direction-optimizing BFS) that are not in the hot paths or do not exist as advertised.
- The MCP server, marketed as safe for AI-assistant integration, has two CRITICAL path-traversal vulnerabilities that allow exfiltration of `~/.ssh/`, `~/.aws/`, etc., from any user who points an AI at a hostile codebase.
- The CLI is documented for CI integration but cannot fail a build because it never returns non-zero.
- Two subcommands that the README implies are equivalent produce different results on the same project.

The good news is that **none of these are fundamental architectural problems**. The mmap/SoA/arena infrastructure is correctly implemented — it just isn't wired in. The path-traversal fixes are 5-10 lines each. The exit-code fix is a `throw ExitCode(_:)` in each `run()`. The default-inconsistency fix is one line. The `ParallelMode.maximum` situation is honest documentation work.

**Recommended path:** address the CRITICAL + correctness block (items 1-7) within 0.1.5; tackle the BLOCKER perf-truthing block (items 8-14) for 0.2.0 with either honest wiring or honest deletion of the unused infrastructure. The codebase has the right bones; it needs to match its advertising.

---

*Detailed per-dimension reports preserved under `.tmp/audit/`. Each section above cross-references those reports for full file:line evidence.*
