# Remediation plan — SwiftStaticAnalysis (rev. 2026-05-15 / post-Batch-1)

This plan replaces the pre-Batch-1 draft. Batch 1 (0.2.1) shipped in
commits `7601464` and `8e76035`; this rev rebatches the remaining work in
light of what was learned during B1 and the new constraints the user has
added since.

**Source audit:** `audit/AUDIT-2026-05-15.md` + 6 per-area scratch files in
`audit/_scratch/`.

**User decisions (still in force):**
- **Scope:** execute Batches 2 → 4 (plus any items pulled forward to honour
  current docs/CHANGELOG claims).
- **Truth-up bias:** **always deliver, no softening.** Every overstated
  README/CHANGELOG/SECURITY claim becomes a real, wired feature in the
  appropriate batch — never a softening rewrite.

**New constraints picked up during Batch 1:**
- **`RegexBuilder` over string regex literals** for developer-authored
  patterns (user note during B1-4). Already applied in `SafeRegex`.
- **`g-cqd/URLBuilder` adoption** for URL construction (user note during
  B1-2). Scheduled for B3 alongside `swift-system` `FilePath` /
  `FileDescriptor` migration. Not in B1's scope.
- **CLAUDE.md conventions** (loaded mid-batch): backticked test method
  names, `try #require` over `Issue.record`, `sut`/`makeSUT` factory,
  avoid `nonisolated(unsafe)`, Swift Testing only, Apple Docs MCP for
  native-API claims. Applied progressively to new code; existing tests
  refactored opportunistically (not as a standalone item) to avoid churn.

---

## Status snapshot

| Batch | Status | Commits | Tests | Notes |
|---|---|---|---|---|
| **B1** — 0.2.1 patch | ✅ shipped | `7601464`, `8e76035` | 1133/1133 | All 4 HIGH MCP findings closed; 17/17 items done |
| **B2** — Structural + feature delivery (0.3.0-α) | pending | — | — | Re-approval required before start |
| **B3** — Native APIs + memory-layer delivery (0.3.0) | pending | — | — | Largest batch; includes B5 items pulled forward |
| **B4** — Benchmark gate (0.3.0) | pending | — | — | Smallest batch; small surgical CI work |
| B5/B6 — Optional polish | deferred | — | — | Not in approved scope |

**0.2.1 highlights** (recap, for context):
- Security HIGH-1..4 all closed (sandbox-validated `index_store_path`,
  `URL(string:)`-based `ReadResource`, bounded `contextCache`, `SafeRegex`).
- Canonical primitives in Core: `LRUDictionary`, `SafeRegex` (with
  RegexBuilder antipattern probes), `GlobMatcher` (anchored whole-match).
- Truth-up: `SymbolQuery.qualifiedName(_:_:)`, `SymbolQuery.selector(_:labels:)`,
  `swaVersion = "0.2.1"` single-source-of-truth, `.swa.json` top-level
  `format` fallback, `--report` validation, README/SECURITY/schema bumps.

---

## Changes vs. the pre-Batch-1 plan

### Items already done in B1 (delete from remaining-work backlog)
- ~~B1-1..B1-17~~ — all shipped.

### Items advanced from later batches into B2/B3
Per "always deliver" — these are tied to current README/CHANGELOG claims:
- SA-IS arena-backed scratch buffers — was B5-1, now **B3-13**.
- `InlineArray<128, UInt64>` MinHash signatures — was B5-2, now **B3-14**.
- M_61 AST fingerprint (replacing 30-bit prime) — was B5-3, now **B3-12**.
- `@unchecked Sendable` removal across the memory layer — **B3-11**.

### Items deferred from B1 into B2
- **Thread `allowsIndexDatabaseCreation` through `UnusedCodeConfiguration`.**
  In B1 the four production `IndexStoreReader` callers all opted in
  (`true`) to preserve behaviour. The MCP-controllable detector path
  should ultimately set `false`. This becomes **B2-1.5** (a sub-item of
  the `IndexStoreReader` move).

### Items added by user input during B1
- **B3-3.5 — adopt `g-cqd/URLBuilder`** at sites that construct file URLs
  (`IndexStoreReader`'s `IndexDatabase` sibling, MCP `Resource(uri:)`).
  Alongside the `swift-system` `FilePath` migration.
- **B6-7 — CLAUDE.md test-convention sweep** (optional; applied
  opportunistically as files are touched).

### Items dropped or right-sized

- Original B2-12 (`drop .iOS(.v18)`): kept, but verified during B1 that
  no production callers depend on the iOS-only build path. Low-risk.
- Original B2-9 (`ParallelMode.maximum` → backpressure): clarified that
  the wire change is small (one branch flip in `MinHashCloneDetector`);
  the streaming infra already exists.
- Original B3-2 (`Foundation → FoundationEssentials`): kept, but now
  follows B3-3 (`swift-system`) because `PathUtilities.swift` rewrite
  unblocks broader migration.

---

## Batch 2 — Structural cleanups + feature delivery (0.3.0-α)

**Estimate:** ~3-5 sessions. Re-approval required at start.

**Theme:** clean public surface, deliver advertised CLI/library features
that exist as scaffolding, drop deferred-from-B1 detail.

### B2-1. Move `IndexStoreReader` (+ helpers) to Core
- **Files:** `Sources/UnusedCodeDetector/IndexStore/{IndexStoreReader.swift,
  IndexStoreFallback.swift}` → `Sources/SwiftStaticAnalysisCore/IndexStore/`.
- **Package.swift:** `IndexStoreDB` becomes a direct dep of
  `SwiftStaticAnalysisCore`; the `SymbolLookup → UnusedCodeDetector`
  dependency goes away (line 163-174). Removes the audit's F-01.
- **Risk:** `SwiftStaticAnalysisCore` is currently iOS-clean; pulling
  `IndexStoreDB` (macOS-only) into Core forces the `.iOS(.v18)` drop
  in B2-12. Sequence B2-1 → B2-12.
- **Tests:** existing tests should pass unchanged.

### B2-1.5. Thread `allowsIndexDatabaseCreation` through detector config
- **Files:** `UnusedCodeConfiguration.swift` (add field, default `true`);
  `UnusedCodeDetector+IndexStore.swift` (pipe through); `SWAMCPServer`
  `handleDetectUnusedCode` sets `false`.
- **Why:** B1's `IndexStoreReader.allowsDirectoryCreation` is safe-by-
  default at the type level, but the MCP path still triggers `true` via
  the default `UnusedCodeConfiguration`. This closes the residual gap.
- **Test:** MCP regression that `detect_unused_code` against a project
  without an existing `IndexDatabase/` returns the typed
  `IndexStoreError.databaseDirectoryMissing` instead of materialising
  the directory.

### B2-2. Demote DataFlow types to `internal`
- **Files:** `Sources/UnusedCodeDetector/DataFlow/CFGBuilder.swift:27,68,
  88,121,153,209,300` and the SCCP / ReachingDefinitions /
  LiveVariableAnalysis files.
- **Test impact:** `@testable import UnusedCodeDetector` where existing
  test files break.

### B2-3. Scope `@_exported import`
- `Sources/SwiftStaticAnalysisCore/SwiftStaticAnalysisCore.swift:7-8` —
  limit to types appearing in this module's public signatures
  (`SyntaxProtocol`, `SourceLocationConverter`, `TokenSyntax`, …).
- `Sources/SwiftStaticAnalysisMCP/SwiftStaticAnalysisMCP.swift:41` —
  limit MCP re-export to `Transport`.

### B2-4. Delete `swa/SWA.swift` local `canonicalizePath`
- `Sources/swa/SWA.swift:1059-1082` deleted; call sites use
  `PathUtilities.canonicalize`.

### B2-5. CLI `findSwiftFiles` symlink hygiene
- `Sources/swa/SWA.swift:1117-1148` align with
  `CodebaseContext.findSwiftFiles` (canonicalise + prefix-check).

### B2-6. Demote utility access levels
- `ProcessExecutor` (`public` → `internal`), `FNV1a`, `AnalysisLogger`.
- Add `@testable import` in tests as needed.

### B2-7. Port `swa-mcp` to `ArgumentParser`
- `Sources/swa-mcp/main.swift`: replace argv parsing with
  `@main struct SWAMCPCommand: AsyncParsableCommand`.

### B2-8. Wire `--auto-build` CLI flag (deliver)
- `Sources/swa/SWA.swift` `Unused`: add `@Flag --auto-build` →
  `UnusedCodeConfiguration.autoBuild`.
- Restore SECURITY.md `--auto-build` narrative as accurate.
- CLITests regression.

### B2-9. `ParallelMode.maximum` engages streaming backpressure (deliver)
- `ParallelMode.swift:17-21`: docstring + behaviour now match.
- `MinHashCloneDetector.detectParallel(in:)`: branch on
  `ParallelMode == .maximum` to use `streamResultsBackpressured`.
- `ParallelVerification`: honour the streaming flag.
- Test asserts backpressure propagation with an instrumented sink.

### B2-10. Forward `excludeNamePatterns` + `ignoredPatterns` (deliver)
- `buildUnusedConfig` reads `config.unused?.excludeNamePatterns`.
- `buildDuplicationConfig` reads `config.duplicates?.ignoredPatterns`.
- ConfigurationTests regression for both.

### B2-11. Default clone-type algorithm flip (deliver)
- `Duplicates` per-type defaults: `exact → .suffixArray`,
  `near → .minHashLSH`, `semantic → .minHashLSH` (was uniformly
  `.rollingHash`).
- `MinHashCloneDetector`: groups produced under `--types near
  --algorithm minHashLSH` carry `.near`, not `.semantic`.
- **Benchmark gate:** before flipping defaults, run `swa-bench
  duplicates-exact` to confirm `.suffixArray` is competitive on the
  project's own `Sources/`. Surface to user if regression >25%.

### B2-12. Drop `.iOS(.v18)` platform
- `Package.swift:12`. Required by B2-1 (Core now depends on
  `IndexStoreDB`).

### B2-13. Plugin hygiene
- `Sources/StaticAnalysisBuildPlugin/Plugin.swift:43-50`: declare source-
  file inputs on the prebuild command so SPM can skip when no Swift
  changed.
- `Sources/StaticAnalysisCommandPlugin/Plugin.swift:51-79`: add
  `process.environment = [:]` defence-in-depth.

### B2-14. `ParallelBFS` auto-selection (deliver)
- `ReachabilityGraph.computeReachable()` and
  `IndexBasedDependencyGraph.computeReachableLocked()`: auto-select
  `computeReachableParallel` when `nodeCount >= threshold` (default
  1000, tunable via `UnusedCodeConfiguration.parallelBFSThreshold`).
- `UnusedCodeConfiguration.useParallelBFS` becomes `Bool?` (nil = auto).

### B2-15. CHANGELOG `[0.3.0-alpha]` section
- Restructured public surface (B2-1..B2-7), feature deliveries
  (B2-8..B2-11, B2-14), plugin hygiene (B2-13), iOS platform drop
  (B2-12), `IndexStore` move + new safe-by-default detector config
  (B2-1, B2-1.5).

**B2 acceptance:** all tests green; `swa-bench` no regression >5%;
SemVer-breaking changes (public→internal demotions, `.iOS` drop) are
called out in CHANGELOG with migration notes.

**B2 commit boundary:** commit, push, checkpoint before B3.

---

## Batch 3 — Native APIs + memory-layer delivery (0.3.0)

**Estimate:** ~5-7 sessions. Re-approval required at start. Biggest batch.

**Theme:** wire the native-API stack the README already advertises;
deliver every perf claim that 0.2.0 oversold; replace string-typed plumbing
with typed builders.

### B3-1. `Bitmap` → `Collections.BitArray`
- Delete `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift` (298 LOC).
  Migrate SA-IS, ParallelBFS, AtomicBitmap consumers.
- **Bail rule:** if `BitArray` is materially slower for SA-IS hot path,
  keep `Bitmap` as `package`-internal and document the keep.

### B3-2. `Foundation` → `FoundationEssentials`
- Audit ~90 import sites. Keep `Foundation` only where the full
  Foundation surface is actually needed (`ProcessExecutor.swift`,
  `PathUtilities.swift` — and B3-3 may eliminate the latter dependency).

### B3-3. `MemoryMappedFile` → `swift-system` `FileDescriptor`
- Open via `FileDescriptor.open(FilePath(path), .readOnly,
  options: [.noFollow])`; size via `fd.size()`.
- `mmap`/`munmap` stay on Darwin (no swift-system mmap yet).
- Drop `@unchecked Sendable` from `MemoryMappedFile`.
- Test: `MemoryMappedFileTests.testRefusesSymlinks`.

### B3-3.5. `g-cqd/URLBuilder` adoption
- Sites: `IndexStoreReader`'s `IndexDatabase` sibling URL,
  MCP `Resource(uri: "file://\(rootPath)")` in
  `SWAMCPServer.registerResourceHandlers`, any
  `URL(fileURLWithPath:)` chain across Core.
- Add `URLBuilder` as a `Package.swift` dependency.
- **Justify before merging:** check `g-cqd/URLBuilder` supports the macOS
  15 / Swift 6.2 target and is `Sendable`-clean.

### B3-4. `FileSlice` `~Escapable`
- Lifetime-bind `FileSlice` to its parent `MemoryMappedFile`; drop
  `@unchecked Sendable`. Update consumers to take `borrowing` parameter.

### B3-5. `withDiscardingTaskGroup`
- `ConcurrencyConfiguration.swift:173` and other
  `withThrowingTaskGroup(of: Void.self)` sites where results are unused.

### B3-6. `SoATokenStorage` Span accessors + `ShingleGenerator` rewrite
- `SoATokenStorage`: expose `var kindSpan: Span<UInt8>`, `offsetSpan`,
  `lengthSpan`, `lineSpan`.
- `ShingleGenerator.generateBlockDocuments` (`Sources/DuplicationDetector
  /MinHash/ShingleGenerator.swift:121, 182-183`): consume the spans
  directly; drop the two per-file `[String]`/`[TokenKind]` materializations
  and the inner `Array(normalizeTokens(Array(tokens), kinds: Array(kinds)))`
  allocation.
- **Benchmark gate:** `swa-bench duplicates-near` before/after.

### B3-7. Dataflow `Set<…>` → bit-vector worklists
- `ReachingDefinitions.swift`, `LiveVariableAnalysis.swift`,
  `SCCPAnalysis.swift`: replace `Set<DefinitionSite>` /
  `Set<VariableID>` with `BitArray` (post-B3-1) indexed on ID.
- Reachability `Set<BlockID>`: bit-vector + indexed priority deque on
  RPO index. Addresses `ReachingDefinitions.swift:363`.
- **Benchmark gate:** `swa-bench unused-reachability` before/after.

### B3-8. `OSSignposter` instrumentation
- New `Sources/SwiftStaticAnalysisCore/Utilities/Signposter.swift` with
  `#if canImport(os.signpost)` guards for Linux.
- Phase boundaries in `swa-bench`, `SwiftFileParser.parse`,
  `DuplicationDetector.detectClones`, `UnusedCodeDetector.detectUnused`,
  `SymbolFinder.find`, BFS phases.

### B3-9. `ParallelMinHashGenerator` / `ParallelProcessor` honour `maxConcurrency`
- Replace unbounded TaskGroups with the chunk-and-drain pattern from
  `Sources/SwiftStaticAnalysisCore/Memory/ZeroCopyParser.swift:437-467`.

### B3-10. `BackpressuredChannelStream.makeChannel` structured cancellation
- `Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift:
  80-89`: wire `withTaskCancellationHandler` or return a cancellable
  handle. Match the docstring.

### B3-11. Drop `@unchecked Sendable` from memory layer (deliver)
- Audit `SoATokenStorage.swift:282`'s `ArenaTokenStorage`. Either prove
  Sendable safety or document the keep.
- CHANGELOG's pre-0.2.0 "`@unchecked Sendable` dropped" claim becomes
  fully true.

### B3-12. Replace AST fingerprint `% 1_000_000_007` with M_61 (deliver)
- `ASTFingerprintVisitor.swift`: switch to `MinHash.mersenne61Reduce`.
- Test: `ASTFingerprintTests.testCollisionRateOnFixture` — empirically
  measure collisions over a synthetic 50k-snippet fixture; expect
  ≤ 1e-3 collision rate (was ~50% pre-fix).

### B3-13. SA-IS arena-backed end-to-end (deliver)
- `SuffixArray.swift:131,145,190,195,210,225,267,287`: every
  `[Int](repeating:count:)` allocation → arena-allocated
  `UnsafeMutableBufferPointer<Int32>`. Type vector encoded in the high
  bit of the `Int32` slot — drops the per-recursion `Bitmap` allocation.
- Skip the `sa.filter { $0 < n }` postpass (record sentinel index +
  one shift).
- `SuffixArrayBuilder.build`: pre-allocate top-level arena once.
- Tests: existing `SAISCorrectnessTests`, `SuffixArrayConstructionTests`
  unchanged.
- **Benchmark gate:** `swa-bench duplicates-exact` — claim
  becomes real.

### B3-14. `InlineArray<128, UInt64>` MinHash signatures (deliver)
- New `MinHashSignature = InlineArray<128, UInt64>`.
- Migrate `[UInt64]` consumers (LSH banding, set operations,
  persistence).
- **Spike before commit:** verify Swift 6.2 `InlineArray` ergonomics in
  the tight LSH banding loop. If unworkable, fall back to a fixed-size
  `Span<UInt64>` wrapper. Don't change perf claim — `InlineArray` is
  the documented commitment.
- Tests: existing `MinHashSignatureTests`,
  `MinHashSIMDEquivalenceTests` unchanged.
- **Benchmark gate:** `swa-bench duplicates-near` — claim becomes real.

### B3-15. CHANGELOG `[0.3.0]` section
- Native-API adoption (B3-1..B3-5, B3-8), memory-layer Span (B3-6),
  bit-vector dataflow (B3-7), `@unchecked Sendable` removal (B3-11),
  AST fingerprint correctness (B3-12), SA-IS arena (B3-13), `InlineArray`
  signatures (B3-14), URLBuilder adoption (B3-3.5). Migration notes for
  any Span-based public API or breaking type changes.

**B3 acceptance:**
- All tests green.
- `swa-bench duplicates-exact` ≥ 10 % faster (B3-13).
- `swa-bench duplicates-near` ≥ 5 % faster (B3-6, B3-14).
- `swa-bench unused-reachability` ≥ 10 % faster (B3-7).
- No regression on any other scenario.

**B3 commit boundary:** commit, push, checkpoint before B4.

---

## Batch 4 — Benchmark gate (0.3.0)

**Estimate:** ~1-2 sessions.

### B4-1. `swa-bench` JSON results
- Standardise output schema in `Sources/swa-bench/main.swift`:
  `{scenario, mean, median, p99, peakRSS, wallTime, gitSha,
  swiftVersion, host}`.
- `--statistical` mode reports median + p99 alongside mean; warmup runs
  configurable.

### B4-2. Persisted baselines
- New `bench/baselines/<scenario>.json` (committed).
- `bench/refresh-baselines.sh` script.

### B4-3. CI comparison + fail-on-regression
- `.github/workflows/benchmarks.yml` compares current JSON to baselines
  via `bench/compare.swift` (or `jq`). Thresholds: ≥ 10 % regression on
  mean OR ≥ 25 % regression on p99 = fail.
- Per-scenario threshold overrides via
  `bench/baselines/<scenario>.thresholds.json`.

### B4-4. Add `duplicates-semantic` scenario
- Currently 5 of 6 scenarios run in CI.

### B4-5. Baseline-refresh workflow
- `.github/workflows/refresh-baselines.yml` — `workflow_dispatch`
  triggered, opens a PR with new baselines.

### B4-6. CHANGELOG `[0.3.0]` (cont.)
- "Benchmarks gated in CI" becomes true.

**B4 acceptance:**
- PR with no perf change → green.
- PR with synthetic 15 % regression in `duplicates-exact` → red, with
  before/after numbers in the PR comment.
- Baselines refreshable via documented workflow.

**B4 commit boundary:** final commit on approved scope.

---

## Batch 5 — Scrub planning artifacts (0.3.0-α.9)

User instruction (recorded 2026-05-15, after `0.3.0-alpha.8`):

> Add a phase to the plan to remove all documentation and comments
> related to the planification artifacts, decision making or audit.

The audit and this plan were process artifacts. Now that the
in-scope work is shipped (Batches 1–4 + selected B5 pull-forwards),
the residue should not survive into the long-term codebase.

### Scope

1. **Delete the `audit/` directory in full** — audit summary,
   per-area scratch files, `.DS_Store`, and this plan itself.
   The `.gitignore` exception `!audit/REMEDIATION-PLAN.md` is
   removed alongside.
2. **CHANGELOG truth-up to substance.** Each `[0.3.0-α.N]` and
   `[0.2.1]` section currently leads with a planification slug
   (`Closes B3-X from the deferred B3.1 cluster`, `audit B3-7`,
   `Batch 1`, etc.). Rewrite to describe what changed and why,
   without referencing the audit, the batches, or the plan IDs.
   Substance stays — the per-section perf tables, behavioural
   notes, and migration callouts are release-log content, not
   planning residue.
3. **Code comment scrub.** Grep-and-trim references to:
   - `audit B?-?`, `audit F-NN`, `audit ID-NN`
   - `Batch N` / `B[1-6]-N` slugs
   - `(audit ...)` parenthetical attributions
   - `0.3.0-α.N` / `0.3.0-alpha.N` version pin slugs that name
     the release in which a refactor landed (release info lives
     in CHANGELOG, not in the code)
   - `pre-0.3`, `post-0.3`, `pre-B`, `post-B` temporal slugs
   - `remediation`, `deferred B*`
   Keep technical WHY comments (invariants, constraints,
   workaround rationale). Lean toward keeping anything that
   would help a reader who doesn't know the plan ever existed.
4. **Final commit's message** documents the scrub directly; the
   git log is the durable record of why the directory disappeared.

### Acceptance

- `audit/` does not exist on `main`.
- `git grep -E 'audit|B[1-6]-[0-9]+|Batch [0-9]|deferred B3|REMEDIATION'`
  returns only false positives (e.g. `IndexStoreReader.findOccurrences`
  matches `audit` inside an unrelated word, etc.).
- `swift build -c release` and `swift test --parallel` pass.
- `bench/compare.sh` is unaffected (this is a docs/comments change).
- CHANGELOG entries still describe every shipped change; only the
  meta-vocabulary is gone.

### Estimate

~0.5 day. Mechanical work + one careful sweep for borderline
comments.

---

## Deferred (B5/B6 — out of approved scope)

These are *not* tied to current README/CHANGELOG claims, so "always
deliver" doesn't force them. Resurface for a separate planning round
after B4.

### B5 — Algorithm SOTA wins (0.4.0+)
- Probability-ordered MultiProbe LSH perturbations (real Lv et al. 2007).
- Bias `LSHIndex.optimalBandsAndRows` toward recall.
- LCP-aware `SuffixArray.search` (Manber-Myers).
- `findMaximalRepeats` stack-based lcp-interval walk (replace
  `Set<Int>` dedup).
- `mergeOverlappingGroups` interval-tree merge (replace O(G²)).
- Hoist invariant SIMD4 coefficient loads in `MinHash.computeSignatureSIMD`.
- `AtomicBitmap` `ManagedBuffer`-backed flat contiguous store.
- Optional `libsais` C-bridge gated by an SPM trait.

### B6 — Polish
- Parameterised Swift Testing rollout across high-value test files.
- Test tag expansion (currently 5 of 90+ suites; add `concurrency`,
  `performance`, `integration`, `mcp`, `index_store`).
- Mutation-testing hard gate per package.
- `SwiftStaticAnalysisOutput` as a library product (or `@_spi`).
- README pin auto-bump on release.
- DocC truth-up sweep (every article line that asserts an
  implementation detail re-verified).
- **B6-7 (new):** apply CLAUDE.md test conventions across existing
  suites — backticks, `sut`/`makeSUT`, `try #require` over
  `Issue.record`, parameterised wherever applicable.

---

## Cross-batch design notes (apply progressively)

These are not work items per se, but constraints on how the remaining
work is written:

- **No `nonisolated(unsafe)` in new code** (per CLAUDE.md). The pattern
  is `Mutex<State>(initial)` with `withLock`. Already followed in
  `DeprecatedFlags` (B1-6). The `SafeRegex.antipatterns` `nonisolated(
  unsafe) let` is grandfathered (it mirrors existing `RegexCache`
  style); revisit in B6.
- **Test conventions** for new tests: backtick method names that read
  as English, `try #require` for unwrapping and pattern destructuring,
  `sut` for the system under test, parameterised cases via
  `@Test(arguments:)` wherever the same assertion runs against multiple
  inputs.
- **Swift Testing only** — no XCTest in new files; existing XCTest
  files migrated only when touched.
- **Apple Docs MCP** is the source of truth for Apple-platform API
  claims (`apple-docs` MCP server). Use it before asserting any
  `Span`/`InlineArray`/`FileDescriptor`/`OSSignposter`/`AsyncChannel`
  capability.
- **Pre-commit hook** runs `swift test --parallel` and a
  `swift-format` pass. Expect a follow-on style commit after each
  batch where the formatter touches multi-line strings / parameter
  lists. Land it as a `style: …` commit immediately after the feature
  commit.
- **Bail rule** (carry-over from pre-B1): if any single item exceeds
  1.5× pre-batch estimate, surface to user before continuing instead of
  re-scoping silently.

---

## Critical files referenced (post-B1)

- `Sources/swa/SWA.swift` — B2-4, B2-5, B2-8.
- `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift` — B2-1.5
  (handle_detect_unused_code), B3-3.5 (Resource URI), B3-8 (signposts).
- `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift` —
  **moves** in B2-1; B2-1.5 threading.
- `Sources/UnusedCodeDetector/DataFlow/*.swift` — B2-2 (public→internal),
  B3-7 (bit-vector worklists).
- `Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift` —
  B3-3, B3-4, B3-11.
- `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift` —
  B3-6, B3-11.
- `Sources/DuplicationDetector/SuffixArray/SuffixArray.swift` — B3-13.
- `Sources/DuplicationDetector/MinHash/MinHash.swift` — B3-14.
- `Sources/DuplicationDetector/MinHash/ShingleGenerator.swift` — B3-6.
- `Sources/DuplicationDetector/Algorithms/ASTFingerprintVisitor.swift` —
  B3-12.
- `Sources/UnusedCodeDetector/Reachability/ReachabilityGraph.swift` —
  B2-14, B3-7.
- `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift` — B3-1.
- `Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift`
  — B3-10.
- `Sources/swa-bench/main.swift` — B4-1, B4-4.
- `.github/workflows/benchmarks.yml` — B4-3, B4-4, B4-5.
- README.md, CHANGELOG.md, SECURITY.md — truth-up across all batches.

---

## Existing primitives to reuse (post-B1 additions in bold)

- **`SwiftStaticAnalysisCore.Utilities.LRUDictionary`** — bounded LRU
  (`B1-3`). Use everywhere a bounded cache is needed.
- **`SwiftStaticAnalysisCore.Utilities.SafeRegex.compile`** — single
  entry point for compiling attacker-controllable regex (`B1-4`).
- **`SwiftStaticAnalysisCore.Utilities.GlobMatcher`** — canonical
  anchored glob → regex (`B1-5`).
- **`SwiftStaticAnalysisCore.Version.swaVersion`** — single source of
  truth for the package version (`B1-11`).
- `Synchronization.Mutex` / `Atomic<UInt64>` — for any new state.
- `ProcessExecutor` — env-allowlisted subprocess for any new spawn.
- `PathUtilities.canonicalize` — replace ad-hoc canonicalisation.
- `ParallelMode.from(legacyParallel:)` — canonical legacy flag mapping.
- `MemoryMappedFile.withRawSpan` — now consumed by hot paths
  (`getCodebaseInfo` after B1-9). Use for any new byte-scan.
- `Arena` / `ThreadLocalArena` — to be the actual consumer for SA-IS
  in B3-13.
- `MinHash.mersenne61Reduce` — to be reused for AST fingerprint in B3-12.
- `swa-bench` — perf verification for B3 + gate substrate for B4.

---

## Verification recipe (per batch)

```bash
# Build & test
swift build -c release
swift test --parallel

# Self-eat-dogfood
swift run swa analyze Sources --format text
swift run swa unused Sources --mode reachability --sensible-defaults
swift run swa duplicates Sources --types exact --types near --min-tokens 100

# Perf gate (informational before B4; gated from B4 on)
swift run swa-bench --output bench/results-$(git rev-parse --short HEAD).json

# MCP smoke
swift run swa-mcp Sources </dev/null   # smoke; piped EOF exits

# Format
swift package plugin --allow-writing-to-package-directory swift-format format Sources/ Tests/

# Mutation testing (optional)
scripts/run-mutation-tests.sh --profile core
```

---

## Recommended next action

**Proceed to B2** with re-approval. The smallest-risk start is the
combined B2-1 + B2-12 (IndexStoreReader move + iOS platform drop) which
together resolve the largest structural finding (F-01) and the
iOS-target inconsistency in one PR-sized unit. The remaining B2 items
(B2-2..B2-14) follow in increasing risk order.

If you'd prefer a different B2 entry point (e.g. lead with B2-8
`--auto-build` to retire SECURITY.md's stale narrative first), say so
when re-approving.
