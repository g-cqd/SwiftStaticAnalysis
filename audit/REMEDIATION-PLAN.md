# Remediation plan — SwiftStaticAnalysis 0.2.0 audit

**Source audit:** `audit/AUDIT-2026-05-15.md` + 6 per-area files in `audit/_scratch/` (4641 lines).
**Branch state:** `main` clean, 30 commits ahead of `origin/main`. New uncommitted files: `audit/`.
**User decisions (recorded):**
- **Scope:** execute Batches 1 → 4.
- **Truth-up bias:** **always deliver, no softening.** Every overstated README/CHANGELOG/SECURITY claim becomes a real, wired feature in the appropriate batch — never a softening rewrite.

This shifts items originally in Batch 5 (SA-IS arena, `InlineArray<128, UInt64>` signatures, M_61 AST fingerprint, drop `@unchecked Sendable` from memory layer) forward into Batches 1-3 because they back current README/CHANGELOG claims.

---

## Context

The 0.2.0 codebase is engineering-strong. The dominant audit finding is **claim/reality drift** — capabilities exist as scaffolding but aren't wired into default code paths. With "always deliver", the work is to make every advertised capability real. Four HIGH-severity MCP issues, one inverted module dependency, 157 unnecessarily-public CFG/dataflow types, and two divergent glob matchers are addressed in parallel.

**Realistic effort with "Batches 1-4 + always deliver":** 12-18 dev-days across multiple sessions. Each batch is independently shippable; we commit between batches. I will pause for re-approval at the start of B2, B3, B4.

---

## Execution model

- **Per-batch:** edit code → `swift build -c release` → `swift test --parallel` → `swift run swa analyze Sources` dogfood → `swift run swa-bench` where perf-relevant → `git commit` → ExitPlanMode-style sanity check before next batch.
- **Truth-up rule:** every doc claim touched by a batch matches the shipped code by the end of the batch. CHANGELOG entry updated as part of the batch.
- **Bail rule:** if any single item's complexity exceeds 1.5× my pre-batch estimate, surface to user before continuing.

---

## Batch 1 — Security HIGH + correctness + small deliverables (0.2.1)

Single PR target. Most items are surgical. "Always deliver" forces a few small wirings here (version, programmatic-API factories, MCP `auto_build` reaffirmation).

### B1-1. MCP `index_store_path` sandbox-validation [HIGH security]
- `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:583-586`: wrap in `try context.validatePath(indexStorePath)`.
- `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift:249`: add `allowsDirectoryCreation: Bool` init parameter; default `false`; MCP path passes `false`, CLI auto-discovery passes `true`.
- Test: `SwiftStaticAnalysisMCPTests/SWAMCPServerTests.testIndexStorePathOutsideSandboxThrows`.

### B1-2. MCP `ReadResource` URI parser [HIGH security]
- `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:1101-1116`: replace `String(uri.dropFirst(7))` with `URL(string: uri)`; assert `scheme == "file"`, `host == nil || host?.isEmpty == true`; take `parsed.path` (percent-decoded).
- Test: parameterised `testReadResourceURIValidation` covering host-bearing, percent-encoded `..`, and valid file URIs.

### B1-3. `SWAMCPServer.contextCache` LRU [HIGH security]
- New `Sources/SwiftStaticAnalysisCore/Utilities/LRUDictionary.swift` (single canonical helper).
- Refactor `Sources/SwiftStaticAnalysisCore/Parsing/SwiftFileParser.swift` LRU to use the helper.
- Refactor `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift`'s `contextCache` to use it; cap = 32.
- Test: `SWAMCPServerTests.testContextCacheEvictsOldestBeyondCap`.

### B1-4. ReDoS-safe regex helper [HIGH security]
- New `Sources/SwiftStaticAnalysisCore/Utilities/SafeRegex.swift` with `static func compile(_ pattern: String) throws -> Regex<AnyRegexOutput>`. Encapsulates: length cap (e.g. 512), static antipattern prefilter (nested quantifiers, backreferences), and embedded comment about caller-supplied wall-clock budget pattern.
- Call from every MCP-reachable regex construction in `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift` (search_symbols already does this — refactor through SafeRegex) and `Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift:153-181` and `Sources/UnusedCodeDetector/Filters/UnusedCodeFilter.swift:114-128`.
- Test: parameterised antipattern fixtures.

### B1-5. Single canonical `GlobMatcher` [security + correctness]
- New `Sources/SwiftStaticAnalysisCore/Utilities/GlobMatcher.swift` with anchored `wholeMatch` semantics. Escapes `+ ( ) [ ] { } ^ $ | \\ ?`. Uses `SafeRegex.compile`.
- Delete `UnusedCodeFilter.matchesGlobPattern` and `CodebaseContext.matchesGlobPattern`. Replace call sites.
- Test: `SwiftStaticAnalysisCoreTests/GlobMatcherTests.swift` — fixtures that exercise the prior `contains` vs `wholeMatch` divergence.

### B1-6. `--parallel` flag mapping fix [correctness bug]
- `Sources/swa/SWA.swift:207-208,369-370`: replace inline `else if parallel { .maximum }` with `ParallelMode.from(legacyParallel: parallel)`.
- Emit deprecation diagnostic via existing `Diagnostic` machinery (or `FileHandle.standardError` if simpler) — printed once per run, not per invocation.
- Test: `CLITests.testLegacyParallelFlagMapsToSafe`.

### B1-7. `RegexCache` LRU correctness [correctness bug]
- `Sources/SwiftStaticAnalysisCore/Utilities/RegexCache.swift:52-56`: replace dict + `keys.first` eviction with `LRUDictionary` from B1-3.
- Test: existing `RegexCacheTests` plus explicit eviction-order assertion.

### B1-8. `SoATokenStorage.append(length: Int)` overflow [correctness bug]
- `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift:155-170`: typed-throw `SoAStorageError.lengthOverflow(length:)` instead of silent `UInt16` truncation. Audit callers; if any legitimately produces `>UInt16.max`, widen the column to `UInt32` and adjust SoA columns + Span accessors.
- Test: `SoATokenStorageTests.testAppendLengthOverflowThrows`.

### B1-9. `CodebaseContext.getCodebaseInfo` mmap rewrite [perf + correctness]
- `Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift:198`: replace `String(contentsOfFile:)` with `MemoryMappedFile.withRawSpan` and byte-scan `0x0A`. Per-file cap 64 MiB (skip with size-recorded above).
- Test: `CodebaseContextTests.testGetCodebaseInfoLargeFileShortCircuits`.

### B1-10. MCP `read_file` extension allowlist trim [security]
- Find `validateForReadFile` helper. Remove `.plist`, `.json`, `.yaml`, `.yml` from the MCP-reachable allowlist. Keep on CLI.
- Test: `SWAMCPServerTests.testReadFileRejectsExtensionsForExfiltration`.

### B1-11. Single source-of-truth version literal [consistency]
- New `Sources/SwiftStaticAnalysisCore/Version.swift` exposing `package let swaVersion = "0.2.1"`.
- Wire into `Sources/swa/SWA.swift:31`, `Sources/swa-mcp/main.swift:25`, `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:49`.
- Test: `SwiftStaticAnalysisCoreTests.testVersionAlignsWithChangelogTopEntry`.

### B1-12. README Programmatic API factories — DELIVER [feature delivery]
The README references `SymbolQuery.qualifiedName("APIClient","shared")` and `SymbolQuery.selector("fetch", labels: ["id","completion"])`. "Always deliver" → add these factories.
- `Sources/SymbolLookup/Models/SymbolQuery.swift:166-209`: add
  ```swift
  static func qualifiedName(_ owner: String, _ member: String) -> SymbolQuery
  static func selector(_ name: String, labels: [String]) -> SymbolQuery
  ```
  Both convenience wrappers over existing primitives.
- Test: `SymbolLookupTests/SymbolQueryFactoriesTests.swift` — round-trip parse to canonical form.

### B1-13. README pin + SECURITY supported-versions bump [doc consistency]
- `README.md:40`: `from: "0.1.4"` → `from: "0.2.1"`.
- `README.md:55`: clarify "all *analyzer* components" vs "MCP server (use `SwiftStaticAnalysisAll`)".
- `SECURITY.md:4`: supported `0.1.x` → `0.2.x`.

### B1-14. `.swa.schema.json` defaults fix [schema correctness]
- Flip `treatPublicAsRoot/treatObjcAsRoot/treatTestsAsRoot/treatSwiftUIViewsAsRoot` schema defaults to `true` to match CLI and library defaults.

### B1-15. `.swa.json` top-level `format` field — WIRE [feature delivery]
- `Sources/swa/SWA.swift`: each subcommand reads `config.format` as the fallback when `--format` is omitted.
- Test: `ConfigurationTests.testTopLevelFormatAppliesAsFallback`.

### B1-16. `--report` errors when `--mode ≠ reachability` [correctness]
- `Sources/swa/SWA.swift` `Unused.run`: throw `ValidationError("--report requires --mode reachability")` instead of silent no-op.
- Test: `CLITests.testReportRequiresReachabilityMode`.

### B1-17. CHANGELOG `[0.2.1]` section
- New section listing B1-1..B1-16. HIGH security fixes called out at top.

### B1 — Acceptance

`swift test --parallel` green; `swa analyze Sources` exits 0/2 cleanly; MCP smoke-test passes; CI green; CHANGELOG updated; all docs consistent with shipped code; 4 MCP HIGH findings closed.

### B1 — Estimate
~2-3 sessions of focused work. Solo-engineer dev-time equivalent ~2 days.

**→ Commit, push, ExitPlanMode-style checkpoint before B2.**

---

## Batch 2 — Structural cleanups + feature delivery (0.3.0-alpha)

User re-approval at start.

### B2-1. Move `IndexStoreReader` to Core [structural]
- Move `Sources/UnusedCodeDetector/IndexStore/{IndexStoreReader.swift, IndexStoreFallback.swift}` (and `IndexStoreError` if defined alongside) to `Sources/SwiftStaticAnalysisCore/IndexStore/`.
- `Package.swift`: add `IndexStoreDB` product to `SwiftStaticAnalysisCore` deps; remove from `SymbolLookup` (no longer needed if Core re-exports); keep on `UnusedCodeDetector`.
- Remove `SymbolLookup → UnusedCodeDetector` dependency at `Package.swift:163-174`.
- Drop `import UnusedCodeDetector` in `Sources/SymbolLookup/Resolution/IndexStoreResolver.swift:7` and `SymbolFinder.swift:8`.
- Test: existing tests should pass unmodified; add `SwiftStaticAnalysisTests.testSymbolLookupDoesNotImportUnusedCodeDetector` (compile-time check via module list).

### B2-2. Demote DataFlow types to internal [structural]
- `Sources/UnusedCodeDetector/DataFlow/CFGBuilder.swift:27,68,88,121,153,209,300` — flip `public` → `internal`. Apply same to SCCP, ReachingDefinitions, LiveVariableAnalysis files.
- Add `@testable import UnusedCodeDetector` where existing test files break.

### B2-3. Scope `@_exported import` [structural]
- `Sources/SwiftStaticAnalysisCore/SwiftStaticAnalysisCore.swift:7-8`: limit re-exports to syntax types actually appearing in this module's public signatures (`SyntaxProtocol`, `SourceLocationConverter`, `TokenSyntax`, …). Use targeted `typealias` declarations.
- `Sources/SwiftStaticAnalysisMCP/SwiftStaticAnalysisMCP.swift:41`: limit MCP re-export to `Transport` (the only type in `SWAMCPServer.start(transport:)`'s public signature).

### B2-4. Delete `swa/SWA.swift` `canonicalizePath` [consistency]
- `Sources/swa/SWA.swift:1059-1082`: delete local; replace call sites with `PathUtilities.canonicalize`.

### B2-5. CLI `findSwiftFiles` symlink hygiene [security defence-in-depth]
- `Sources/swa/SWA.swift:1117-1148`: add `.isSymbolicLinkKey`; canonicalize each discovered path and verify it stays within the analyzed root.

### B2-6. Demote utility access levels [structural]
- `Sources/SwiftStaticAnalysisCore/Utilities/ProcessExecutor.swift:23` `public` → `internal`.
- Same for `FNV1a` and `AnalysisLogger`.

### B2-7. Port `swa-mcp` to `ArgumentParser` [consistency]
- `Sources/swa-mcp/main.swift`: replace hand-rolled argv parsing with `@main struct SWAMCPCommand: AsyncParsableCommand`.

### B2-8. Wire `--auto-build` CLI flag — DELIVER [feature delivery]
- `Sources/swa/SWA.swift` `Unused` struct: add `@Flag(name: .customLong("auto-build")) var autoBuild: Bool = false`.
- Wire through `buildUnusedConfig` → `UnusedCodeConfiguration.autoBuild`.
- Restore SECURITY.md's `--auto-build` references as accurate (the narrative was correct; the flag now exists).
- Test: `CLITests.testAutoBuildFlagWires`.

### B2-9. `ParallelMode.maximum` engages streaming backpressure — DELIVER [feature delivery]
- `Sources/SwiftStaticAnalysisCore/Configuration/ParallelMode.swift:17-21`: rewrite the comment; `.maximum` no longer means "only highThroughput shape" — it also flips a `useStreaming: Bool` flag.
- `Sources/DuplicationDetector/MinHash/MinHashCloneDetector.swift` `detectParallel(in:)`: when `ParallelMode == .maximum`, dispatch via `streamResultsBackpressured` end-to-end.
- `Sources/DuplicationDetector/Parallel/ParallelVerification.swift`: branch on the new streaming flag.
- Test: `ParallelModeTests.testMaximumEngagesBackpressuredStreaming`, ideally with an instrumented sink that proves backpressure propagation.

### B2-10. Forward `excludeNamePatterns` + `ignoredPatterns` to detectors — DELIVER [feature delivery]
- `Sources/swa/SWA.swift` `buildUnusedConfig`: read `config.unused?.excludeNamePatterns` into `UnusedCodeConfiguration.ignoredPatterns`.
- `buildDuplicationConfig`: read `config.duplicates?.ignoredPatterns` into `DuplicationConfiguration.ignoredPatterns`.
- Test: `ConfigurationTests.testExcludeNamePatternsFlowsToDetector`, `testDuplicationIgnoredPatternsFlowsToDetector`.

### B2-11. Default clone-type algorithm flip — DELIVER [feature delivery]
- `Sources/swa/SWA.swift` `Duplicates` defaults: per-type default algorithm — `exact → .suffixArray`, `near → .minHashLSH`, `semantic → .minHashLSH` (current default is `.rollingHash` for all). README clone-type table becomes true.
- `MinHashCloneDetector`: ensure groups produced under `--types near --algorithm minHashLSH` are labelled `.near`, not `.semantic`.
- Benchmark: run `swa-bench` before/after; if `.suffixArray` is materially slower for `exact` on the project's own `Sources/`, surface to user.
- Test: `DuplicationDetectorTests.testDefaultAlgorithmPerTypeMatchesREADME`, `testMinHashGroupLabellingMatchesRequestedType`.

### B2-12. Drop `.iOS(.v18)` platform [correctness]
- `Package.swift:12`: remove `.iOS(.v18)`. (IndexStoreDB is macOS-only; iOS CI gate doesn't exist; SECURITY.md is macOS-oriented.)
- Alternatively, gate IndexStoreDB-dependent code behind `#if canImport(IndexStoreDB)` and add a smoke iOS-build CI step. Default: drop unless user objects.

### B2-13. Plugin hygiene [defence-in-depth]
- `Sources/StaticAnalysisBuildPlugin/Plugin.swift:43-50`: declare source-file inputs on the `.prebuildCommand` so SPM skips when no Swift files changed.
- `Sources/StaticAnalysisCommandPlugin/Plugin.swift:51-79`: add `process.environment = [:]` defence-in-depth even with the SPM sandbox.

### B2-14. `ParallelBFS` auto-selection — DELIVER [feature delivery]
- `Sources/UnusedCodeDetector/Reachability/ReachabilityGraph.swift:296`, `Sources/UnusedCodeDetector/IndexStore/IndexBasedDependencyGraph.swift:221`: auto-select `computeReachableParallel` when `nodeCount >= 1000` (threshold tunable via `UnusedCodeConfiguration.parallelBFSThreshold`).
- `Sources/UnusedCodeDetector/Configuration/UnusedCodeConfiguration.swift:37`: `useParallelBFS` default → `nil` (auto) with `Bool?` semantics, or remove the manual flag entirely.
- Test: `ParallelBFSTests.testAutoSelectsAtThreshold`.

### B2-15. CHANGELOG `[0.3.0-alpha]` section
- Restructured public surface (B2-1..B2-7), feature deliveries (B2-8..B2-11, B2-14), plugin hygiene (B2-13), iOS platform drop (B2-12).

### B2 — Acceptance
All tests green. `swa-bench` does not regress > 5% on any scenario. SemVer-breaking changes (public→internal demotions) clearly enumerated in CHANGELOG with migration notes.

### B2 — Estimate
~3-5 sessions. Solo-engineer ~4-5 days.

**→ Commit, push, checkpoint before B3.**

---

## Batch 3 — Native APIs + memory-layer delivery (0.3.0)

User re-approval at start.

### B3-1. `Bitmap` → `Collections.BitArray` [native-API]
- Delete `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift` (298 LOC). Migrate consumers: SA-IS, ParallelBFS, AtomicBitmap. Run benchmarks.
- If `BitArray` is materially slower for SA-IS's hot path, keep `Bitmap` as a `package`-internal type and document why.

### B3-2. `Foundation` → `FoundationEssentials` migration [native-API + portability]
- Audit ~90 files. Keep `Foundation` in `ProcessExecutor.swift` (Process) and `PathUtilities.swift` (NSString). Refactor the latter to use `FilePath` (B3-3) where possible.
- All others switch to `FoundationEssentials`.

### B3-3. `MemoryMappedFile` → `swift-system` `FileDescriptor` [native-API]
- `Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift`: open via `FileDescriptor.open(FilePath(path), .readOnly, options: [.noFollow])` and `fd.size()`; keep `mmap`/`munmap` via Darwin (no swift-system mmap yet).
- Drop `@unchecked Sendable` on `MemoryMappedFile` — store `FileDescriptor` (Sendable) + `Atomic<UnsafeRawPointer?>` for mapping pointer.
- Test: existing `MemoryTests` (must still pass); add `MemoryMappedFileTests.testRefusesSymlinks`.

### B3-4. `FileSlice` `~Escapable` [native-API + concurrency]
- `Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift`: redesign `FileSlice` as `~Escapable` bound to its `MemoryMappedFile`'s lifetime. Drop `@unchecked Sendable`.
- Update consumers (parser, ignore-directive scanner) to use the `borrowing` parameter pattern.

### B3-5. `withDiscardingTaskGroup` [native-API]
- `Sources/SwiftStaticAnalysisCore/Concurrency/ConcurrencyConfiguration.swift:173`: `withThrowingTaskGroup(of: Void.self)` → `withThrowingDiscardingTaskGroup`.
- Audit other `withThrowingTaskGroup(of: Void.self)` and `withTaskGroup(of: Void.self)` sites; convert if results are unused.

### B3-6. `SoATokenStorage` Span accessors + `ShingleGenerator` Span-driven rewrite [native-API + perf]
- `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift`: expose `var kindSpan: Span<UInt8>`, `var offsetSpan: Span<UInt32>`, `var lengthSpan: Span<UInt16>` (or `UInt32` post-B1-8), `var lineSpan: Span<UInt32>`.
- `Sources/DuplicationDetector/MinHash/ShingleGenerator.swift:121,182-183`: rewrite `generateBlockDocuments` and `generate(tokens:kinds:)` to consume the spans directly. Drop the two per-file `[String]`/`[TokenKind]` materializations and the inner `Array(normalizeTokens(...))` allocations.
- Benchmark with `swa-bench duplicates-near` before/after — this is one of the biggest expected wins.

### B3-7. Dataflow `Set<…>` → bit-vector worklists [perf]
- `Sources/UnusedCodeDetector/DataFlow/ReachingDefinitions.swift`, `LiveVariableAnalysis.swift`, `SCCPAnalysis.swift`: replace `Set<DefinitionSite>` / `Set<VariableID>` with `BitArray` (post-B3-1) indexed on ID.
- Reachability `Set<BlockID>` worklist: replace with bit-vector + indexed priority deque on RPO index (covers audit item `ReachingDefinitions.swift:363`).
- Benchmark with synthetic CFG fixtures and `swa-bench unused-reachability`.

### B3-8. `OSSignposter` instrumentation [observability]
- New `Sources/SwiftStaticAnalysisCore/Utilities/Signposter.swift` wrapping `OSSignposter` with `#if canImport(os.signpost)` guards for Linux.
- Phase boundaries in `swa-bench` and analyzer entry points (`SwiftFileParser.parse`, `DuplicationDetector.detectClones`, `UnusedCodeDetector.detectUnused`, `SymbolFinder.find`, BFS phases).

### B3-9. `ParallelMinHashGenerator` / `ParallelProcessor` honour `maxConcurrency` [correctness + perf]
- `Sources/DuplicationDetector/Parallel/ParallelVerification.swift` and `ParallelProcessor` (find with grep): replace unbounded TaskGroup with the chunk-and-drain pattern from `Sources/SwiftStaticAnalysisCore/Memory/ZeroCopyParser.swift:437-467`.
- Test: `ConcurrentParsingTests.testMaxConcurrencyHonoured` (instrumented count).

### B3-10. `BackpressuredChannelStream.makeChannel` structured cancellation [correctness]
- `Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift:80-89`: wire `withTaskCancellationHandler` or return a cancellable handle. Match the docstring.
- Test: `BackpressuredChannelStreamTests.testCancellationPropagates`.

### B3-11. Drop `@unchecked Sendable` from memory layer — DELIVER [native-API + CHANGELOG truth-up]
- After B3-3 and B3-4, audit `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift:282`'s `ArenaTokenStorage` `@unchecked Sendable`. Either prove Sendable safety with `~Copyable`/sendability boundaries or document why it must remain.
- CHANGELOG's "`@unchecked Sendable` dropped" claim becomes true.

### B3-12. Replace AST fingerprint `% 1_000_000_007` with M_61 — DELIVER [correctness + perf]
- `Sources/DuplicationDetector/Algorithms/ASTFingerprintVisitor.swift`: replace 30-bit prime modulus with `MinHash.mersenne61Reduce`. Collision rate at N≈50k snippets drops from ~50% to negligible.
- Test: `ASTFingerprintTests.testCollisionRateOnFixture`.

### B3-13. SA-IS arena-backed end-to-end — DELIVER [perf + README truth-up]
- `Sources/DuplicationDetector/SuffixArray/SuffixArray.swift:131,145,190,195,210,225,267,287`: replace every `[Int](repeating:count:)` with arena-allocated `UnsafeMutableBufferPointer<Int32>` via the existing `Arena` / `ThreadLocalArena`. Encode type vector in the high bit of the `Int32` slot — drops the per-recursion bitmap allocation too.
- Skip the `sa.filter { $0 < n }` postpass (record sentinel index, single shift).
- `SuffixArrayBuilder.build`: pre-allocate top-level arena once.
- Test: existing `SAISCorrectnessTests` (must pass unchanged); `SuffixArrayConstructionTests` (correctness on randomized inputs).
- Benchmark `swa-bench duplicates-exact` before/after — claim becomes real.

### B3-14. `InlineArray<128, UInt64>` MinHash signatures — DELIVER [perf + README truth-up]
- `Sources/DuplicationDetector/MinHash/MinHash.swift:54` and all consumers: introduce `MinHashSignature = InlineArray<128, UInt64>`. Migrate `[UInt64]` consumers (LSH banding, set operations, persistence).
- Need to verify Swift 6.2 `InlineArray` ergonomics are sufficient (subscripting, iteration in tight loops). If not, fall back to a fixed-size `Span<UInt64>` wrapper.
- Test: existing `MinHashSignatureTests`, `MinHashSIMDEquivalenceTests` (must pass unchanged).
- Benchmark `swa-bench duplicates-near` — claim becomes real.

### B3-15. CHANGELOG `[0.3.0]` section
- Native-API adoption (B3-1..B3-5, B3-8), `@unchecked Sendable` removal (B3-11), memory-layer Span (B3-6), bit-vector dataflow (B3-7), AST fingerprint correctness (B3-12), SA-IS arena (B3-13), `InlineArray` signatures (B3-14). Migration notes for Span-based public API.

### B3 — Acceptance
All tests green. `swa-bench` shows ≥ 10% improvement on `duplicates-exact` (B3-13), ≥ 5% on `duplicates-near` (B3-6, B3-14), ≥ 10% on `unused-reachability` (B3-7). No regression elsewhere.

### B3 — Estimate
~5-7 sessions. Solo-engineer ~6-8 days. Biggest batch.

**→ Commit, push, checkpoint before B4.**

---

## Batch 4 — Benchmark gate (0.3.0)

User re-approval at start.

### B4-1. `swa-bench` JSON results
- Standardize output JSON schema in `Sources/swa-bench/main.swift`: `{scenario, mean, median, p99, peakRSS, wallTime, gitSha, swiftVersion, host}`.
- `--statistical` mode reports median + p99 alongside mean; warmup runs configurable.

### B4-2. Persisted baselines
- New `bench/baselines/<scenario>.json` files (committed). One per scenario.
- New `bench/refresh-baselines.sh` script that re-runs swa-bench and writes baselines.

### B4-3. CI comparison + fail-on-regression
- `.github/workflows/benchmarks.yml`: post-run step compares current JSONs to baselines via a new `bench/compare.swift` (or `jq` script). Threshold: ≥ 10% regression on mean OR ≥ 25% regression on p99 = fail.
- Per-scenario threshold override via `bench/baselines/<scenario>.thresholds.json`.

### B4-4. Add `duplicates-semantic` scenario
- `.github/workflows/benchmarks.yml`: add `duplicates-semantic` to the loop (currently 5 of 6).
- Generate its baseline.

### B4-5. Baseline-refresh workflow
- `.github/workflows/refresh-baselines.yml`: `workflow_dispatch`-triggered, runs `bench/refresh-baselines.sh`, commits baselines on a branch, opens PR. Or alternatively, a `[refresh-baseline]` PR-comment trigger.

### B4-6. CHANGELOG `[0.3.0]` (cont.)
- "Benchmarks gated in CI" becomes true. README "Performance" claim verified.

### B4 — Acceptance
PR with no perf change → green. PR with synthetic 15% regression in `duplicates-exact` → red, with clear before/after numbers in the PR comment. Baselines refreshable via documented workflow.

### B4 — Estimate
~1-2 sessions. Solo-engineer ~1-2 days.

**→ Final commit. End of approved scope. B5/B6 deferred for separate planning.**

---

## Deferred to later batches (not in approved scope)

These items remain in the audit but are **out of scope** for the Batches 1-4 + "always deliver" mandate because they aren't tied to current README/CHANGELOG claims:

- B5: multi-probe LSH probability-ordered perturbations (real Lv et al. 2007), LSH bias toward recall, LCP-aware suffix-array search, libsais C-bridge SPM trait, `AtomicBitmap` `ManagedBuffer` refactor, SIMD4 coefficient hoist, maximal-repeats stack walk, mergeOverlappingGroups interval tree.
- B6: parameterised Swift Testing rollout, expanded test tags, mutation-testing hard gate, `SwiftStaticAnalysisOutput` library product, README pin auto-bump on release.

---

## Critical files referenced

- `Sources/swa/SWA.swift` — B1-6, B1-11, B1-15, B1-16, B2-4, B2-5, B2-8, B2-10, B2-11.
- `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift` — B1-1, B1-2, B1-3, B1-4, B1-10, B1-11.
- `Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift` — B1-4, B1-5, B1-9.
- `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift` — B1-1, moved in B2-1.
- `Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift` — B3-3, B3-4, B3-11.
- `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift` — B1-8, B3-6, B3-11.
- `Sources/DuplicationDetector/SuffixArray/SuffixArray.swift` — B3-13.
- `Sources/DuplicationDetector/MinHash/MinHash.swift` — B3-14.
- `Sources/DuplicationDetector/MinHash/ShingleGenerator.swift` — B3-6.
- `Sources/DuplicationDetector/Algorithms/ASTFingerprintVisitor.swift` — B3-12.
- `Sources/UnusedCodeDetector/DataFlow/*.swift` — B2-2, B3-7.
- `Sources/UnusedCodeDetector/Reachability/ReachabilityGraph.swift` + `ParallelBFS.swift` — B2-14, B3-7.
- `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift` — B3-1.
- `Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift` — B3-10.
- `Sources/swa-bench/main.swift` — B4-1, B4-4.
- `.github/workflows/benchmarks.yml` — B4-3, B4-4.
- `Sources/SymbolLookup/Models/SymbolQuery.swift` — B1-12.
- README.md, CHANGELOG.md, SECURITY.md, `.swa.schema.json` — truth-up across all batches.

---

## Existing utilities to reuse

- `OrderedDictionary` (swift-collections) — for LRU in B1-3, B1-7.
- `Synchronization.Mutex` / `Atomic<UInt64>` — for any new state in B3-3.
- `ProcessExecutor` — for any new subprocess (none new planned; reused in B2-13 defence-in-depth note).
- `PathUtilities.canonicalize` — B2-4 replacement.
- `Diagnostic` machinery — B1-6 deprecation diagnostic.
- `ParallelMode.from(legacyParallel:)` — B1-6.
- `MemoryMappedFile.withRawSpan` — B1-9, B3-6 (now consumed by hot path, not just exposed).
- `Arena` / `ThreadLocalArena` — B3-13 (the actual consumer).
- `MinHash.mersenne61Reduce` — B3-12 (reused to fix AST fingerprint).
- `swa-bench` harness — B3 perf verification + B4 gate.

---

## Verification recipe (per batch)

```bash
swift build -c release
swift test --parallel
swift run swa analyze Sources --format text
swift run swa unused Sources --mode reachability --sensible-defaults
swift run swa duplicates Sources --types exact --types near --min-tokens 100
swift run swa-bench --output bench/results-$(git rev-parse --short HEAD).json   # B4+ also compares vs baseline
swift run swa-mcp Sources </dev/null   # smoke
# format
swift package plugin --allow-writing-to-package-directory swift-format format Sources/ Tests/
# mutation (optional)
scripts/run-mutation-tests.sh --profile core
```

---

## Persistence

On ExitPlanMode approval, my first action is to copy this plan to `audit/REMEDIATION-PLAN.md` and commit (alongside the already-untracked `audit/AUDIT-2026-05-15.md` + `_scratch/`). The plan file under `~/.claude/plans/` is ephemeral; the repo-tracked copy is the source of truth going forward.
