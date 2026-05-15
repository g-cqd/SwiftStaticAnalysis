# Changelog

All notable changes to SwiftStaticAnalysis will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0-alpha.4] - Unreleased

Lifts **B3-6 (partial)** out of the deferred B3.1 cluster: the
`ShingleGenerator` half can ship without the
`SoATokenStorage`-Span-accessor half (which strictly requires the
`FileSlice` `~Escapable` lifetime rework). 1135 tests green; baselines
refreshed.

### Performance

- **B3-6a — `ShingleGenerator.generateBlockDocuments` rewritten to
  iterate `ArraySlice<TokenInfo>` directly.** Pre-0.3 the hot path
  materialised an N-element `[String]` (token texts) and an
  N-element `[TokenKind]` (token kinds) per file via
  `sequence.tokens.map(\.text)` / `.map(\.kind)`. The new
  `generate(tokenInfos:)` + `normalizeTokenInfos(_:)` pair reads
  `text` and `kind` straight off each `TokenInfo`, eliminating both
  allocations. Measured **−6.5% mean wall-time on
  `duplicates-near`** over `Sources/` (0.502s → 0.470s, 122 files);
  the benchmark baseline has been refreshed accordingly.

### Deferred (still in B3.1)

The Span-accessor half of B3-6 (`SoATokenStorage.kindSpan` /
`offsetSpan` / `lengthSpan` / `lineSpan`) requires `FileSlice`
`~Escapable` (B3-4) for safe zero-copy lifetime. Stays paired with the
memory-layer cluster in B3.1.

## [0.3.0-alpha.3] - Unreleased

Batch 4 of the 0.2.0 audit remediation
([`audit/REMEDIATION-PLAN.md`](audit/REMEDIATION-PLAN.md)). Closes audit
F-15 ("benchmarks gated in CI" claim). 1135 tests green; six benchmark
baselines committed under `bench/baselines/`.

### Truth-up: benchmarks are now an actual CI gate

- **B4-1 — `swa-bench` JSON schema extended.** Reports now carry
  `wallSecondsMedian`, `wallSecondsP99`, `peakRSSBytesP99`, plus an
  `environment { gitSha, swiftVersion, host, platform }` block for
  cross-machine baseline traceability. `--statistical` flag prints
  median + p99 to stderr alongside the human-readable mean. **Add
  fields; never rename** — `bench/compare.sh` consumes
  `wallSecondsMean` / `wallSecondsP99` directly.
- **B4-2 — Persisted baselines.** `bench/baselines/*.json` for every
  scenario committed. `bench/refresh-baselines.sh` regenerates them
  locally or from CI; tune via `SWA_BENCH_WARMUP` /
  `SWA_BENCH_ITERATIONS` env vars.
- **B4-3 — `bench/compare.sh` is the gate.** Compares fresh results
  to baselines; fails (exit 1) when any scenario exceeds **+10 % mean
  OR +25 % p99** over its baseline. Per-scenario overrides via
  `bench/baselines/<scenario>.thresholds.json`. Emits a Markdown table
  suitable for the PR comment.
- **B4-4 — `duplicates-semantic` scenario added.** The CI loop pre-0.3
  ran 5 of 6 scenarios. Now runs all 6 (audit F-15).
- **B4-5 — `refresh-baselines.yml` workflow.** `workflow_dispatch`
  triggered; requires a `reason` input; opens a PR with the
  regenerated baselines so the change is reviewable.

The README's pre-0.3 "gated in CI via `.github/workflows/benchmarks.yml`"
claim is finally accurate. PRs that touch the analyzer source paths
now trigger the workflow, run the six scenarios, compare against the
committed baselines, and **fail the build** on regression.

## [0.3.0-alpha.2] - Unreleased

Partial Batch 3 of the 0.2.0 audit remediation
([`audit/REMEDIATION-PLAN.md`](audit/REMEDIATION-PLAN.md)). The
small-scope native-API + perf-truth-up items shipped; the coupled
memory-layer rework cluster (B3-1/B3-2/B3-3/B3-3.5/B3-4/B3-6/B3-7/B3-11/B3-14)
exceeds session budget and is deferred to a focused **B3.1** follow-up.
1135 tests green.

### Truth-up: perf claims now backed by code

- **B3-12 — AST fingerprint switches to M_61.**
  `FingerprintHasher` replaces `% 1_000_000_007` (a 30-bit prime that
  collided ~50% at N≈50 000 snippets) with the same Mersenne-61
  reduction the SIMD MinHash kernel already uses. Regression test
  verifies (a) every output stays under 2^61 − 1, (b) > 9 990 / 10 000
  distinct hashes on a deterministic probe set.
- **B3-13 — SA-IS is now arena-backed end-to-end.**
  `SAIS.build` creates an `Arena` at the top of the call and threads
  it through recursion. The working `sa` buffer is an
  `UnsafeMutableBufferPointer<Int>` from the arena; the second
  `placeLMSSuffixesOrdered` pass reuses the same buffer in place (no
  fresh `[Int]` allocation). `placeLMSSuffixes`,
  `placeLMSSuffixesOrdered`, `inducedSortLType`, `inducedSortSType`,
  `assignLMSNames` all take the buffer pointer instead of `inout [Int]`.
  `SuffixArrayBuilder.build`'s `sa.filter { $0 < n }` postpass is
  replaced by an in-place `removeFirst()` (the sentinel sorts to
  index 0). The README's pre-0.3 "Arena-backed scratch buffers" claim
  is now true. Existing `SAISCorrectnessTests`,
  `SuffixArrayConstructionTests`, `LCPCorrectnessTests` pass unchanged.

### Native-API adoption + concurrency hygiene

- **B3-5 — `withThrowingDiscardingTaskGroup`** at
  `ParallelProcessor.forEach`. Drops the per-task result-slot
  allocation; any throw cancels siblings + propagates automatically.
- **B3-9 — `ParallelProcessor.map`/`compactMap` and
  `ParallelMinHashGenerator.computeSignatures` now honour their
  `maxConcurrency` caps** via the streaming-bounded pattern from
  `ZeroCopyParser.extractParallel:437-467`. Pre-0.3 the
  documents-per-task ratio scaled with input size, ignoring the cap.
- **B3-10 — `BackpressuredChannelStream.makeChannel` cancellation.**
  The producer Task is now wrapped in `withTaskCancellationHandler`;
  on cancel the channel is finished *immediately* rather than at the
  operation's next `Task.isCancelled` checkpoint. The docstring
  promise (consumer-side iteration termination drains the producer)
  is now actually wired.
- **B3-8 — `OSSignposter` instrumentation.** New
  `SwiftStaticAnalysisCore.Utilities.Signposter` with
  `#if canImport(os.signpost)` guards for Linux. Phase intervals on
  `DuplicationDetector.detectClones`, `UnusedCodeDetector.detectUnused`,
  and `SymbolFinder.find` show up as named regions in Instruments'
  os_signpost track.

### Deferred to B3.1 (focused memory-layer + algorithm rework)

The remaining audit items in B3 form a tightly coupled cluster — the
memory-layer Sendable cleanup, `swift-system` `FilePath`/`FileDescriptor`
adoption, `URLBuilder` integration, `FileSlice` `~Escapable` lifetime,
`SoATokenStorage` Span accessors + `ShingleGenerator` Span-driven
rewrite, dataflow `Set<…>` → `BitArray` worklists, and `MinHashSignature`
generic-over-N `InlineArray<N, UInt64>` migration are all interlocking
and exceed the per-batch budget. They land in a single focused B3.1
batch:

- B3-1 — `Bitmap` → `Collections.BitArray` (benchmark-gated swap).
- B3-2 — `Foundation` → `FoundationEssentials` (~88 files).
- B3-3 — `MemoryMappedFile` → `swift-system` `FileDescriptor`.
- B3-3.5 — `g-cqd/URLBuilder` adoption at file-URL construction sites.
- B3-4 — `FileSlice` `~Escapable` lifetime-bound to its
  `MemoryMappedFile`.
- B3-6 — `SoATokenStorage` `Span<T>` accessors + `ShingleGenerator`
  Span-driven rewrite (drops two per-file `[String]`/`[TokenKind]`
  allocations).
- B3-7 — Dataflow `Set<DefinitionSite>` / `Set<VariableID>` →
  `BitArray` worklists + RPO-indexed priority deque.
- B3-11 — Drop `@unchecked Sendable` from `MemoryMappedFile`,
  `FileSlice`, `ArenaTokenStorage` (depends on B3-3 + B3-4).
- B3-14 — `MinHashSignature` generic over `let N: Int` so the SIMD
  path's `InlineArray<128, UInt64>` claim is honoured for the default
  width without breaking the `numHashes != 128` test suite.

The README/CHANGELOG still references some of these as if shipped;
truth-up of those bullets happens at the start of B3.1 (deliver in the
same batch).

## [0.3.0-alpha] - Unreleased

Batch 2 of the 0.2.0 audit remediation
([`audit/REMEDIATION-PLAN.md`](audit/REMEDIATION-PLAN.md)). Structural
cleanups + feature delivery for capabilities the pre-0.3 README/CHANGELOG
already advertised. 15 items shipped; 1134 tests green.

### Breaking changes (since 0.2.x)

- **Platforms**: `.iOS(.v18)` dropped from `Package.swift`. `IndexStoreDB`
  is macOS-only and now sits in `SwiftStaticAnalysisCore`'s dependency
  closure — there was never a working iOS configuration. Pre-0.3
  consumers that listed `iOS` as a deployment target will see the
  resolver narrow to macOS 15.
- **Module graph**: `IndexStoreReader`, `IndexStoreFallbackManager`,
  `FallbackConfiguration`, and `IndexStoreError` moved from
  `UnusedCodeDetector.IndexStore` to
  `SwiftStaticAnalysisCore.IndexStore`. `SymbolLookup` no longer
  depends on `UnusedCodeDetector` (audit F-01). Consumers that
  `import UnusedCodeDetector` purely to reach `IndexStoreReader`
  should switch to `import SwiftStaticAnalysisCore`.
- **`DetectionMode`** moved from `UnusedCodeDetector.Models` to
  `SwiftStaticAnalysisCore.Configuration`. Re-imported transitively;
  no consumer change required.
- **`UnusedCodeConfiguration.useParallelBFS`** is now `Bool?` (was
  `Bool`). `nil` (the new default) means "auto-select against
  `parallelBFSThreshold`"; `true`/`false` force the backend.
- **`@_exported import` scope narrowed**: Core no longer re-exports
  `SwiftParser` (it was never in a public signature); `SwiftStaticAnalysisMCP`
  no longer re-exports the full `MCP` module — only `MCP.Transport`,
  the one type that appears in `SWAMCPServer.start(transport:)`.
- **`ProcessExecutor`** demoted from `public` to `internal`. It was
  never used outside `SwiftStaticAnalysisCore`; making the subprocess
  launcher API public was an audit-flagged footgun (F-17).
- **`UnusedCodeDetector.DataFlow.*`** demoted from `public` to
  `internal` (157 declarations across `CFGBuilder`, `SCCPAnalysis`,
  `ReachingDefinitions`, `LiveVariableAnalysis`). The dataflow
  subsystem has no external consumers; the public surface was an
  unintentional ABI commitment (audit F-03). Use `@testable import
  UnusedCodeDetector` if you were poking at these.

### Security (defence-in-depth)

- **B2-1.5** — `IndexStoreReader.allowsDirectoryCreation` now flows from
  `UnusedCodeConfiguration` via the new
  `allowsIndexDatabaseCreation: Bool` field (default `true` to preserve
  CLI/programmatic behaviour). `SWAMCPServer.handleDetectUnusedCode`
  sets it to `false`, so a hostile MCP prompt cannot drive a
  `createDirectory` side-effect even when an `IndexDatabase/` directory
  is absent. Surfaces `IndexStoreError.databaseDirectoryMissing`
  instead.
- **B2-13** — `StaticAnalysisCommandPlugin` now scrubs
  `process.environment = [:]` before spawning the `swa` tool, closing
  the residual `DYLD_INSERT_LIBRARIES` / `SWIFTPM_HOOKS_DIR`
  passthrough that the SPM-plugin sandbox couldn't fix via
  `ProcessExecutor` (Core is gated out of plugins).

### Features (truth-up — delivered, not softened)

- **B2-8** — `swa unused --auto-build` CLI flag delivered. Pre-0.3 the
  flag was referenced by SECURITY.md and DocC but only reachable via
  the programmatic API and `.indexStoreAutoBuild` preset. CLITests
  asserts the flag is advertised in `--help`.
- **B2-9** — `ParallelMode.maximum` actually engages
  `BackpressuredChannelStream`-backed streaming verification in
  `MinHashCloneDetector.detectParallel`. New
  `ParallelMode.usesStreamingVerifier`, `ParallelCloneConfiguration.useStreamingVerifier`,
  and `DuplicationConfiguration.useStreamingVerifier` thread the
  choice from CLI to detector.
- **B2-10** — `.swa.json` `unused.excludeNamePatterns` and
  `duplicates.ignoredPatterns` now actually reach the detectors.
  Pre-0.3 they were decoded by `SWAConfiguration` and silently dropped
  by `buildUnusedConfig`/`buildDuplicationConfig`.
- **B2-11** — Per-type default algorithm flip. With no `--algorithm`
  override:
  - `--types exact` → `.suffixArray` (was `.rollingHash`)
  - `--types near` → `.minHashLSH` (was `.rollingHash`)
  - `--types semantic` → `.minHashLSH` (was `.rollingHash`)
  - Mixed sets → `.rollingHash` (catch-all preserved)
  The README clone-type table now matches reality. New
  `defaultAlgorithm(forCloneTypes:)` helper. `parseAlgorithm` now
  returns `DetectionAlgorithm?` instead of silently defaulting.
- **B2-11 (cont.)** — MinHash routing for `--types near`: when the user
  requests `.near` with `.minHashLSH`, `DuplicationDetector` now
  routes through `MinHashCloneDetector` and **relabels** the output
  groups `.near` instead of leaking the detector's intrinsic
  `.semantic` label.
- **B2-14** — `ParallelBFS` auto-selection. When the user didn't pin
  `--parallel-mode`/`--parallel`, `DependencyExtractor.detect` chooses
  `computeReachableParallel` for graphs with ≥
  `UnusedCodeConfiguration.parallelBFSThreshold` nodes (default 1000)
  and sequential BFS for smaller graphs. CLI now forwards `nil` for
  the auto path instead of always forcing parallel.

### Consistency / API hygiene

- **B2-1** — `SymbolLookup → UnusedCodeDetector` dependency removed
  (audit F-01).
- **B2-4** — `swa/SWA.swift` local `canonicalizePath` deleted (audit
  F-05). The CLI now routes path canonicalisation through
  `PathUtilities.canonicalize`, matching the MCP `CodebaseContext`
  surface.
- **B2-5** — CLI `findSwiftFiles` re-resolves each enumerated path and
  checks it stays inside the analysis root (audit F-06). Symlinks
  pointing at `/tmp/.build/...` or external artifact trees no longer
  smuggle generated code into the analysis.
- **B2-7** — `swa-mcp` ported to `ArgumentParser`. `--path=…`,
  `--help`, `--version` all use the same parsing engine as the rest
  of the toolchain.

## [0.2.1] - Unreleased

Batch 1 of the 0.2.0 audit remediation
([`audit/REMEDIATION-PLAN.md`](audit/REMEDIATION-PLAN.md)). Closes the four
HIGH-severity MCP findings from `audit/_scratch/03-security.md` and fixes
several correctness bugs surfaced by the audit. No public API removals;
one access-level expansion (`SWAMCPServer` gains internal test surface).

### Security (MCP)

- **HIGH-1 closed — `index_store_path` sandbox-validated.**
  `handleDetectUnusedCode` now routes the attacker-controllable
  `index_store_path` MCP argument through `CodebaseContext.validatePath`,
  preventing both the arbitrary-directory read and the implicit
  `createDirectory(.../IndexDatabase)` write outside the codebase root
  that pre-0.2.1 servers exposed. Defence-in-depth: `IndexStoreReader.init`
  now takes an `allowsDirectoryCreation: Bool = false` parameter; CLI
  paths explicitly opt in (`true`), while any caller that forgets gets
  the safe-by-default semantics. `IndexStoreError.databaseDirectoryMissing`
  surfaces the refusal.
- **HIGH-2 closed — `ReadResource` URI parser hardened.** The pre-0.2.1
  `String(uri.dropFirst(7))` is replaced with `URL(string: uri)` plus
  scheme/host/empty-path checks. Percent-encoded `%2F` no longer round-
  trips into the sandbox-prefix check; host-bearing `file://example.com/...`
  URIs are rejected outright instead of silently collapsing to a relative
  sandbox path. Factored into the testable
  `SWAMCPServer.parseFileURI(_:)` helper.
- **HIGH-3 closed — `SWAMCPServer.contextCache` is bounded.** The
  unbounded `Dictionary<String, CodebaseContext>` is replaced with a
  32-entry `LRUDictionary`. A hostile MCP prompt can no longer pin
  unbounded memory by flood-creating distinct codebase paths.
- **HIGH-4 closed — `SafeRegex` central compiler.** New
  `SwiftStaticAnalysisCore.SafeRegex` enforces a length cap and a
  RegexBuilder-typed nested-quantifier prefilter. Every MCP-reachable
  regex construction (`search_symbols`, glob translation in
  `CodebaseContext.matchesGlobPattern` and `UnusedCodeFilter`) now
  routes through it.
- **`read_file` extension allowlist trimmed.** `.plist`, `.json`,
  `.yaml`, `.yml` are removed from the MCP-accessible allowlist —
  those extensions commonly host secrets in real-world Swift
  projects (`fastlane/Appfile`, `.env.json`, generated
  `GoogleService-Info.plist`). The CLI is unaffected.

### Correctness

- **`GlobMatcher` consolidation.** Two divergent glob implementations
  (`contains`-based in `UnusedCodeFilter`, `wholeMatch`-based in
  `CodebaseContext`) collapsed into a single
  `SwiftStaticAnalysisCore.GlobMatcher` with anchored whole-match
  semantics. `Tests` and `Sources` as bare patterns no longer match
  any path containing the segment — they match only the literal
  filename. Existing fast paths (`**/Tests/**`,
  `**/*Tests.swift`, `**/Fixtures/**`) preserved.
- **`--parallel` flag mapping aligned with README.** The deprecated
  CLI flag now routes through `ParallelMode.from(legacyParallel:)`
  (mapping `true → .safe`), matching the documented contract and the
  `.swa.json` decoder. A once-per-run deprecation diagnostic is
  emitted on stderr.
- **`SoATokenStorage.append(...:Int,...:Int,...)` no longer truncates.**
  The `Int`-typed convenience overload now throws
  `SoAStorageError.lengthOverflow`/`.columnOverflow` instead of
  silently clamping `length`/`column` to `UInt16.max`. Propagated
  through `ZeroCopyParser.extractTokensToSoA` (typed throws).
- **`RegexCache` LRU eviction is now genuine LRU.** The
  `Dictionary.keys.first` eviction (undefined order) is replaced by
  the new canonical `LRUDictionary` (built on swift-collections'
  `OrderedDictionary`). `SwiftFileParser` and `ZeroCopyParser` also
  migrate to `LRUDictionary`.
- **`--report` validates its mode.** `swa unused --report --mode simple`
  now exits 64 with a clear diagnostic instead of silently producing a
  regular unused-code listing.
- **`CodebaseContext.getCodebaseInfo` no longer allocates
  per-file `String`s.** The line-count loop now uses `MemoryMappedFile`
  + `withRawSpan` and skips files over 64 MiB.

### Features (truth-up)

- **`SymbolQuery.qualifiedName(_:_:)` and `SymbolQuery.selector(_:labels:)`
  added.** These factories are referenced by README's "Programmatic
  API" examples but were missing before this release.
- **`.swa.json` top-level `format` field applied.** Each subcommand
  resolves `--format` > `.swa.json:format` > `.xcode`. The field was
  decoded but unused pre-0.2.1.

### Consistency

- **Single source-of-truth `swaVersion`.** New
  `SwiftStaticAnalysisCore.Version.swift` is the only place version
  literals live; `swa`, `swa-mcp`, and `SWAMCPServer` all reference it
  (pre-0.2.1 the MCP server advertised the stale literal `"0.1.0"`).
  `VersionTests.testVersionMatchesChangelog` is the regression pin.
- **README pin bumped (`0.1.4` → `0.2.1`).** SECURITY.md supported-
  versions table updated (`0.1.x` → `0.2.x` supported).
- **README umbrella clarification.** The "all components including the
  MCP server" sentence is reworded — `SwiftStaticAnalysis` exposes
  analyzer modules only; `SwiftStaticAnalysisAll` is required for MCP.
- **`.swa.schema.json` defaults aligned with CLI/library defaults.**
  `treatPublicAsRoot`, `treatObjcAsRoot`, `treatTestsAsRoot`,
  `treatSwiftUIViewsAsRoot` all flip schema default `false → true`.

### Internal

- New canonical primitives in `SwiftStaticAnalysisCore.Utilities`:
  `LRUDictionary` (bounded LRU), `SafeRegex` (ReDoS-guarded regex
  compilation, RegexBuilder antipattern probes),
  `GlobMatcher` (anchored glob → regex translation).
- Test-only introspection helpers in `SWAMCPServer`
  (`_test_getContext`, `_test_handleDetectUnusedCode`,
  `_test_contextCacheCount`, `_test_contextCacheContains`) so security
  regressions are observable without driving the full MCP transport.

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
