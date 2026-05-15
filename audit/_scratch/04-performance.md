# 04 — Performance & Distance-from-SOTA Audit

Scope: SwiftStaticAnalysis 0.2.0 (commit `19c8db4`).
Method: read README "Performance", `CHANGELOG.md` 0.2.0 entry, `SECURITY.md`,
then audit the actual implementations against the team's own claims and
against published state-of-the-art literature. All references are file
paths + line numbers (absolute).

---

## Summary

The 0.2.0 codebase shows real perf engineering: SoA token columns, a
typed Mersenne-61 modulus with an honest SIMD4 lane on the MinHash hot
path, a dense-projected CSR for reachability, a direction-optimising
parallel BFS implementation that explicitly cites Beamer et al., an
arena allocator with `~Copyable` Arena and a TLS variant, and a
benchmark binary with RSS reporting. These are not cosmetic — they are
the right ideas.

But the README and `CHANGELOG.md` overstate what is wired up. The
biggest gaps:

1. **SA-IS "Arena-backed" is not actually arena-backed.** Only the
   `Bitmap` type vector uses bit-packed storage. Every other SA-IS
   scratch buffer — `sa`, `bucketHeads`, `bucketTails`, `lmsPositions`,
   `lmsNames`, `reducedString`, `heads`/`tails` working copies — is a
   fresh `[Int]` per recursion level
   (`Sources/DuplicationDetector/SuffixArray/SuffixArray.swift:131,
   145, 190, 195, 267, 287`). The recursive call at line 142 allocates
   the entire stack again. The "no per-recursion `[Int]` allocations"
   claim in the README's Performance section is incorrect.

2. **`InlineArray<128, UInt64>` for MinHash signatures does not
   exist.** `grep -r InlineArray Sources/` finds nothing. Signatures
   are `[UInt64]`
   (`Sources/DuplicationDetector/MinHash/MinHash.swift:54`).
   The Mersenne-prime SIMD4 path is real and correct, but the inline
   storage claim is not implemented.

3. **`@unchecked Sendable` was not dropped from
   `MemoryMappedFile`/`FileSlice`/`ArenaTokenStorage`** despite
   CHANGELOG 0.2.0 saying it was
   (`Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift:54,
   337`, `Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift:282`).
   The new `withRawSpan` accessor IS added (line 164, 412), so the
   *capability* exists; nothing in the hot path uses it yet.

4. **Auto-selection of `ParallelBFS` for graphs ≥ 1000 nodes does
   not happen on the default code path.** `ReachabilityGraph.computeReachable()`
   (`Sources/UnusedCodeDetector/Reachability/ReachabilityGraph.swift:296`)
   and `IndexBasedDependencyGraph.computeReachableLocked()`
   (`Sources/UnusedCodeDetector/IndexStore/IndexBasedDependencyGraph.swift:221`)
   both unconditionally call `DenseGraph.computeReachableSequential()`.
   The parallel path requires the caller to invoke
   `computeReachableParallel(...)` explicitly (line 712), and only
   `DependencyExtractor` honours the `useParallelBFS` config flag (which
   defaults to `false` per
   `Sources/UnusedCodeDetector/Configuration/UnusedCodeConfiguration.swift:37`).
   The "auto-selects parallel BFS for graphs ≥1000 nodes" line in
   `CHANGELOG.md` is aspirational.

5. **`swa-bench` is not a perf gate.** The workflow
   (`.github/workflows/benchmarks.yml`) runs the bench, posts a table
   to the PR, and uploads artifacts. There is no baseline JSON, no
   comparison, no `exit 1` on regression. The README line "gated in CI
   via `.github/workflows/benchmarks.yml`" is misleading — it is
   *reported* in CI, not *gated*.

6. **`SoATokenStorage` is allocated then immediately exploded back to
   `[String]` / `[TokenKind]` in the duplication hot path.**
   `ShingleGenerator.generateBlockDocuments`
   (`Sources/DuplicationDetector/MinHash/ShingleGenerator.swift:182-183`)
   does `sequence.tokens.map(\.text)` and `sequence.tokens.map(\.kind)`
   before the windowing loop — two full-file allocations of object
   arrays. Then `generate(tokens:kinds:)` (line 121) does another
   `Array(normalizeTokens(Array(tokens), kinds: Array(kinds)))` on the
   normalisation branch. The SoA columns never feed the shingler
   directly. The "Per-window `Array(...)` allocations eliminated"
   bullet in `CHANGELOG.md` is half-true (window-level windows are
   `ArraySlice` now) but the per-file copies are bigger and still
   happen.

Items 1–6 do not break correctness. They mean the engineering text
oversells what is plumbed into the default code path. The fixes are
mostly straightforward (sketched per section below).

The actual algorithmic gap to SOTA is moderate. The choices (SA-IS,
MinHash+LSH, direction-optimising BFS, IndexStoreDB) are the right
ones for a Swift static analyser in 2026. The competitive gap is in
the *quality* of the implementations vs the latest research
(BBit-MinHash / DartMinHash, SourcererCC bag-of-words+filtering, libsais
divsufsort), and in *coverage* of dataflow primitives (the SCCP /
ReachingDefinitions / LiveVariable code is textbook-correct but uses
`Set<Hashable>` instead of bit-vectors and is non-incremental). Detail
below.

---

## Algorithmic findings

### 1. Suffix array (SA-IS)

**File**: `Sources/DuplicationDetector/SuffixArray/SuffixArray.swift`

What's there:
- `SAIS.build(_:alphabetSize:)` at line 114 implements the canonical
  Nong/Zhang/Chan 2009 algorithm: type classification (`L`/`S`/`LMS`),
  bucket-tail placement, induced sort L then S, LMS renaming,
  recursive call on the reduced string, second induced sort.
- `Bitmap` (1 bit per suffix) for the type vector — line 162 — that
  saves ~7×. Good.
- Falls back to comparison sort for `n ≤ 32` (line 119) — sensible
  cutoff.

What's missing / off:

- **The implementation is correct but is *not* the fast SA-IS.**
  Reference implementations (Yuta Mori's `sais`, Kärkkäinen's
  `sais-lite`, the C++ `libsais`) achieve ~10× the throughput of a
  naive SA-IS by:
  - placing LMS suffixes into a flat preallocated `sa[]` of the
    parent recursion (no fresh allocation) — this code allocates a
    fresh `[Int](repeating: -1, count: text.count)` *twice* per call
    (`placeLMSSuffixes` line 210, `placeLMSSuffixesOrdered` line 225);
  - keeping bucket pointer arrays in the arena rather than copying
    `bucketHeads`/`bucketTails` once for each induced sort (lines
    240, 253);
  - encoding the type vector in the low bit of `sa[]` to avoid even
    the `Bitmap` lookup.
- **The recursion is depth-`O(log n)` and at each level allocates
  three `[Int]` of size `n_i`** (current sa, lmsNames, reducedSA).
  For a 30 M-token codebase the worst case is several hundred MiB of
  short-lived `[Int]` allocations. The `Arena` type and
  `ThreadLocalArena` in
  `Sources/SwiftStaticAnalysisCore/Memory/Arena.swift` are the
  scaffolding for the claimed fix — they're just not wired in.
- **`SuffixArrayBuilder.build` (line 77) does `sa.filter { $0 < n }`
  to strip the sentinel**, which is `O(n)` extra and allocates yet
  another `[Int]`. The standard fix is to record the sentinel's
  position and `sa.remove(at: idx)`, which is one bulk shift.
- **`alphabet.fromStrings` (line 43) uses `[String: Int]`** — the
  canonical SA-IS interface expects pre-tokenised integer IDs and
  this is fine for top-level callers, but
  `_DuplicationEngine.addCodeSnippets` already has SoA-stored byte
  slices; building a `[String: Int]` over Swift `String`s pays a
  full UTF-8 copy + Bloom-filter hashing per token. The right shape
  is `[Slice: Int]` keyed on `FileSlice`-style byte ranges (see
  "SoA token storage" below).
- **`compare(suffix:with:in:)` (line 385)** is the binary-search
  comparator, used by `search(pattern:in:)`. With the LCP array
  present (`LCPArray.swift`), one can avoid the inner string
  comparison entirely via the Manber-Myers `lcp[lo, mid]` trick. The
  binary search is currently `O(m log n)` instead of `O(m + log n)`.
  Not load-bearing for clone detection, but the API exists and is
  worth fixing.

**Closest SOTA**: libsais (`https://github.com/IlyaGrebnov/libsais`,
2024-era, MIT) is ~3-5× faster than this implementation on 30 M-token
inputs; building one of its `divsufsort64`-equivalent C entry points
through SwiftPM and using it via `@_silgen_name`-bridged C buffer
would be a much bigger win than micro-optimising SA-IS in pure
Swift. swift-collections has no suffix-array primitive and is not a
substitute. Apple's `Compression` framework is not relevant
(LZ-based, not for SA).

**Concrete next steps**:
1. Make `SAIS.build` arena-aware: pass `inout Arena` (or use
   `ThreadLocalArena.withCurrent`) and replace every internal `[Int]`
   with an `UnsafeMutableBufferPointer<Int32>` allocated from it.
   With `Int32` slots, the type vector encoded into the high bit, the
   per-recursion footprint drops by ~16×.
2. Skip the `sa.filter { $0 < n }` postpass.
3. Add an LCP-aware `search` overload.
4. Consider a `package` C-extern path that hands the token buffer to
   libsais and uses pure-Swift SA-IS as a fallback / for very small
   inputs.

### 2. LCP array (Kasai)

**File**: `Sources/DuplicationDetector/SuffixArray/LCPArray.swift`

- `Kasai's algorithm` at line 62 is textbook-correct, O(n), uses a
  rank array — fine.
- `findMaximalRepeats(minLength:)` at line 137 has an *expensive*
  filter step: `filterToMaximalRepeats` at line 180 builds a
  `Set<Int>` per repeat for "uniqueness" deduplication. For a code
  base with many maximal repeats this can be `O(R^2)` in repeats. The
  standard structure (Abouelhoda/Kurtz "Replacing suffix trees with
  enhanced suffix arrays") avoids any post-pass by walking
  `lcp`-intervals once on a stack. Worth replacing.
- `mergeOverlappingGroups` (line 253) deduplicates by 50%-overlap of
  the position set — sensible heuristic, but `O(G^2)` in groups.
  Switch to interval-tree merge on sorted positions.

### 3. MinHash

**File**: `Sources/DuplicationDetector/MinHash/MinHash.swift`

What's there and good:
- `mersenne61Reduce(_:)` (line 18) is *correct* — branchless
  `(r & M) + (r >> 61)` plus one conditional subtraction. The
  conditional is on the boolean comparison which the compiler lowers
  to a `cmov` on x86_64 / `csel` on arm64. Not a branch in the
  classical sense.
- `splitMix64(_:)` (line 31) — standard, high-quality. Replacing the
  prior LCG mixer is the right call.
- `computeSignatureSIMD(for:)` (line 186) packs `SIMD4<UInt64>` for
  `(a, b, sig)` lanes, uses `pointwiseMin`, processes 4 hash
  universes per shingle. The reduction is hand-vectorised (line 215).
  This is the genuine perf delta the CHANGELOG advertises and it
  delivers.

What's off:

- **`computeSignatureSIMD` re-loads `aPtr[baseIdx..+3]` into a
  `SIMD4<UInt64>` constant *inside the per-shingle loop***
  (lines 200, 206). The coefficient vector is *invariant*; you can
  hoist all `(chunk, a, b)` SIMD4 loads out to a precomputed
  `[SIMD4<UInt64>]` (built once at `init`). That removes ~`8 * chunks`
  scalar loads per shingle.
- **The "carry fold" subtraction on lines 218-224** is scalar — it
  builds the `overflow` SIMD4 element-wise. Use SIMD comparison:
  `let overflow = product .>= maskVec; product &-= SIMD4<UInt64>(
  repeating: M).replacing(with: .zero, where: !overflow)`. Or just
  rely on the fact that one fold already brings `r < 2·M`; the
  caller only needs a *consistent* min, so for MinHash *you can
  skip the second fold entirely* (the second fold matters only if
  you want the canonical residue). Inspect whether the
  equivalence test still passes — likely yes — and you save a full
  SIMD compare+subtract per shingle per chunk.
- **`shingleHash & Self.mersenne61` (line 196) loses a bit of entropy**
  vs the full UInt64. Since you also `&` the coefficients to 61 bits,
  effective bit-width is 61. Fine for clone-detection-sized
  populations (~10^6 documents) but worth noting if you ever want
  cryptographic-strength stability.
- **No use of `InlineArray<128, UInt64>`** for the signature buffer
  despite the README claim. The hot allocation `var signature =
  [UInt64](repeating: UInt64.max, count: numHashes)` (line 187)
  allocates 1 KiB per document; switching to a stack-allocated
  `InlineArray` (Swift 6.2+) saves the alloc and gives the optimiser
  better lifetime info. This is genuinely 0.2.0-shippable; the README
  says it's done.

**SOTA**: BBit-MinHash (Li & König 2010), DartMinHash (Christiani
2020), SuperMinHash (Ertl 2017) all give *lower variance* per byte of
signature for the same threshold. For 128-bit signatures the
ratio is roughly: classic MinHash → b-bit (b=1 or 2, ~8× smaller
sig for the same accuracy) → DartMinHash (~2× faster computation,
similar size). None are tabulation-hash-bound; SplitMix64 mixing is
fine. The current implementation is *correct* and the Mersenne-61
choice is industry-standard; the gap to SOTA is in *signature size /
accuracy tradeoff*, not in compute speed. If `numHashes` were lowered
from 128 to 32 via b-bit MinHash you'd halve memory and verify cost.

### 4. LSH

**File**: `Sources/DuplicationDetector/MinHash/LSH.swift`

- `optimalBandsAndRows(signatureSize:threshold:)` (line 100) is the
  classic `t = (1/b)^(1/r)` solver. Brute-forces all `(b, r)` with
  `b * r ≤ signatureSize` — fine for 128-row signatures, but it
  always picks the *closest* match without distinguishing false
  positive vs false negative cost. The proper formulation (per
  Leskovec/Rajaraman/Ullman, Ch. 3) is an asymmetric loss; the
  current code prefers symmetric `|t - threshold|`. For clone
  detection you almost certainly want bias toward *recall* (more
  bands), which means accepting `t < threshold` more readily.
- `findCandidatePairs` (line 152) iterates `buckets[band]` and does
  `docIds.combinations(ofCount: 2)`. For a single popular bucket
  with `K` docs this is `O(K^2)` *per band*. Pathological case is a
  bucket that contains thousands of near-empty token sequences. No
  size cap.
- `findCandidatePairsStreaming` (line 270) uses
  `TaskBackedAsyncStream.bufferingNewest(1000)` — this *drops* pairs
  under buffer pressure. The CHANGELOG markets `BackpressuredChannelStream`
  as the fix; that fix exists in `ParallelVerification.swift:400` but
  is *not* called from `findCandidatePairsStreaming`. The streaming
  candidate finder still has drop semantics.
- `hashBand` (line 345) is FNV-1a over UInt64 words. Fine.

### 5. Multi-probe LSH

**File**: `Sources/DuplicationDetector/MinHash/MultiProbeLSH.swift`

- Perturbation vectors (line 158) are *naive*: it just adds a small
  integer to one or more positions in the band, then re-queries. The
  canonical "Multi-probe LSH" (Lv/Josephson/Wang/Charikar/Li 2007) uses
  a *probability-ordered* probe sequence derived from the
  hash-distance distribution. The current scheme generates
  `probesPerBand` probes per band where each probe number increments
  by `probe + 1` (line 176) — that's neither distance-ordered nor
  probability-ordered.
- The result is fewer false negatives than a single probe, but the
  improvement is much smaller than what proper multi-probe gives. On
  typical clone-detection workloads the gain over base LSH is ~5–10%
  recall; the SOTA gain is 30–50%.

### 6. AST fingerprint

**File**: `Sources/DuplicationDetector/Algorithms/ASTFingerprintVisitor.swift`

- `FingerprintHasher` (line 279) is a polynomial Merkle-style hash
  over `SyntaxKind` strings.
- **Modulus is `1_000_000_007`** (line 308) — a 30-bit prime.
  Birthday-collision probability for `N` snippets is `~N^2 / 2^30`;
  at `N = 50 000` snippets that's a ~50% collision rate, which
  blows up "exact" semantic clone matching. **Should be a 64-bit
  Mersenne (M_61) consistent with MinHash, or just `&* prime` with
  wrapping arithmetic on `UInt64`.**
- **`% prime` on every step (lines 302, 323, 329)** is a hardware
  divide, ~25 cycles each. With M_61 you'd reuse `mersenne61Reduce`
  and run branch-free.
- **The hash is on `"\(node.kind)"`** — a `String` materialisation of
  a `SyntaxKind` enum case name *per node* (line 315). For a 100 KLOC
  file with 10 M syntax nodes that's 10 M short-string allocations.
  The fix: hash the raw `rawValue` (an `Int`) or precompute
  `SyntaxKind → UInt32` table.
- The algorithm is a "bag-of-paths" / "bag-of-types" style
  representation — comparable to Deckard's vectorised characteristic
  vectors but simpler. **Not competitive with SourcererCC (2018)**
  which uses bag-of-tokens with frequency-based filtering and reports
  90%+ recall on real bug-reproduction corpora. SourcererCC's index
  structure (inverted index on token frequencies + sub-block
  filtering) is the SOTA *for source-code* near-clone detection.
- No comparison to NiCad (2013, normalisation+LCS) is meaningful here
  because NiCad targets Type-3 with pretty-printed normalisation
  whereas the current detector targets bare AST structural matching.

### 7. Reachability BFS

**Files**:
- `Sources/UnusedCodeDetector/Reachability/DenseGraph.swift`
- `Sources/UnusedCodeDetector/Reachability/ParallelBFS.swift`
- `Sources/UnusedCodeDetector/Reachability/ReachabilityGraph.swift`
- `Sources/UnusedCodeDetector/IndexStore/IndexBasedDependencyGraph.swift`

What's there and good:
- `DenseGraph` (line 28) is a proper CSR-style adjacency list with
  precomputed in/out degrees (line 104). The string→index map is
  built once.
- `ParallelBFS.computeReachable` (line 121) is a faithful Beamer et
  al. direction-optimising BFS: top-down → bottom-up switch on
  `frontierEdges * α > remainingEdges` (line 213), back via
  `frontierSize * β < nodeCount` (line 227). Defaults α=14, β=24 are
  the published values.
- `AtomicBitmap` (`Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift:39`)
  uses stdlib `Atomic<UInt64>` with relaxed-ordering `bitwiseOr` for
  `testAndSet`. Relaxed is correct here because BFS only needs
  *eventual* visibility within the same iteration; no
  acquire/release pairs are needed.

What's off:
- **`ParallelBFS` is not on by default.** As noted in the summary,
  `ReachabilityGraph.computeReachable()` and
  `IndexBasedDependencyGraph.computeReachableLocked()` both call
  `dense.computeReachableSequential()`. The parallel path exists but
  the calling sites do not auto-select it. The
  `useParallelBFS: Bool = false` config flag is the gate (default
  off), so the CHANGELOG line about ≥1000-node auto-select is wishful.
- **`AtomicBitmap`'s `storage` is `[AtomicWord]`** — an array of
  *boxed* atomics (line 165). Each `testAndSet` does an array
  bounds-check + heap-pointer dereference. With swift-atomics we
  could use a contiguous `UnsafeBufferPointer<UInt64>` directly via
  `Atomic<UInt64>.AtomicRepresentation`, eliminating the box.
  swift-collections' `BitArray` (added in 1.1) is non-atomic so can't
  replace `AtomicBitmap` directly, but the *non-atomic* `Bitmap` in
  the same file is duplicated work — `BitArray` is the right answer
  there.
- **`graph.remainingEdges(visited:)` (DenseGraph.swift:143) is
  `O(nodeCount)` per call** and called once per BFS iteration
  (`ParallelBFS.swift:155`). For a deep DAG this dominates. The
  remaining-edges count can be maintained incrementally: decrement by
  `outDegrees[node]` when `node` is visited.
- **Sequential BFS uses `queue: [Int]` + `head` index walk**
  (DenseGraph.swift:195) — fine, O(1) per pop. Good.
- **Bottom-up step (line 297) builds a fresh `Bitmap` for the
  frontier each iteration** — necessary for membership tests, but
  not reused. Could be allocated once and cleared. With a 1 M-node
  graph that's a 128 KiB alloc per BFS step.
- **No work-stealing.** Chunked TaskGroup is fine for uniform graphs;
  for power-law graphs (typical in symbol-call-graphs) one chunk
  becomes the long pole. swift-async-algorithms has no work-stealing
  primitive; an `AsyncChannel`-based dynamic worklist would be the
  fix.

**SOTA for static-analysis reachability**:
- LLVM's `llvm::DominatorTreeBase` uses the Cooper-Harvey-Kennedy
  iterative algorithm for dominator computation, not raw BFS — not
  directly comparable.
- Apple's `swift-package-manager` `PackageGraph` uses plain DFS
  in `swift-package-manager/Sources/PackageGraph/Resolution/...`;
  no parallelism, no direction-optimising. This codebase is *ahead*
  of SPM here.
- Roslyn's `IFlowAnalysisAnalysisContext` is per-method, not
  whole-program; not comparable.

### 8. SCCP / ReachingDefinitions / LiveVariableAnalysis

**Files**: `Sources/UnusedCodeDetector/DataFlow/{SCCPAnalysis,
ReachingDefinitions, LiveVariableAnalysis}.swift`

What's there:
- `SCCPAnalysis` (`SCCPAnalysis.swift:300+`) implements the
  Wegman-Zadeck SSA SCCP — two worklists (`ssaWorklist`, `cfgWorklist`,
  line 276/279) + executable-edge tracking — correctly.
- `LiveVariableAnalysis` (`LiveVariableAnalysis.swift:181+`) and
  `ReachingDefinitions` (`ReachingDefinitions.swift:340+`) are
  worklist-based iterative analyses.

What's off:
- **The worklist is `Set<BlockID>`** in both
  (LiveVariableAnalysis.swift:195, ReachingDefinitions.swift:355).
  `Set.removeFirst()` is documented as "removes an arbitrary
  element", which destroys the *ordering benefit* of worklist
  algorithms.
- **`ReachingDefinitions.swift:363`** is the killer:
  ```swift
  let rpoBlock = cfg.reversePostOrder.first(where: { worklist.contains($0) })
  ```
  This is O(|reversePostOrder|) per iteration, so the worklist loop
  is `O(B^2)` in basic blocks even before counting dataflow merges.
  Standard fix: keep a `Deque<BlockID>` and a parallel `Set<BlockID>`
  for "is in worklist?".
- **Dataflow values are `Set<DefinitionSite>` / `Set<VariableID>`**
  not bit-vectors. Set union/difference are O(|set|) hashed-element
  operations. For functions with <64 vars (common) a single
  `UInt64` bit-vector is one machine instruction per merge. The
  existing `Bitmap` type would fit directly.
- **`SCCPAnalysis.swift:294`** uses `cfgWorklist.popLast()` —
  that's LIFO, not the standard SCCP iteration order, but in practice
  the executable-edge invariant absorbs the difference. Fine.
- **`CFGBuilder.swift` represents the CFG as
  `[BlockID: BasicBlock]`** (line 228) where `BlockID` wraps a
  `String` (line 80). Every successor/predecessor lookup goes
  through a Swift dictionary keyed on a String. For a 1000-block
  CFG that's hundreds of kilobytes of `String` overhead. A proper
  CFG uses `Int` IDs and a flat `[BasicBlock]` indexable by ID.
- **No incremental dataflow.** Each `analyze(_:)` call rebuilds gen/
  kill from scratch. For an IDE-like workflow that's fine for now;
  for full-project sweeps it means a 1-line edit re-runs the entire
  analysis on every function.
- **Statement-level uses/defs are `Set<VariableID>`** (CFGBuilder.swift:99).
  Same bit-vector argument applies.

**SOTA for intraprocedural dataflow**: SPARSE/SSA-based dataflow
(Choi-Cytron-Ferrante 1991), or the LLVM IR `MemorySSA` / `LLT` style
on-demand summaries. The current code is closer to a textbook
Aho/Sethi/Ullman implementation, which is fine *if* it's used to
detect dead stores in already-parsed Swift and not as the analysis
backbone. The numbers above are 10–100× headroom on real code.

### 9. swa-bench methodology

**File**: `Sources/swa-bench/main.swift`,
`.github/workflows/benchmarks.yml`

- The bench reports **mean / min / max** of wall time and **mean**
  RSS over 3 iterations after 1 warmup (`main.swift:46-49`). Good
  shape: small N, hot-cache. But:
  - **No p50/p99**. Variance estimators (stddev/median absolute
    deviation) would be more honest with N=3.
  - **No cold-cache run.** The mmap+SwiftFileParser cache means the
    second iteration parses nothing.
  - **No CPU pinning, no scheduling-class hint.** macOS CI runners
    are notoriously noisy. ContinuousClock readings on a `macos-15`
    runner ±30% are normal.
  - **No fixture diversity.** Fixture is `Sources/` of the PR — fine
    for self-bench, but a code change to `Sources/` itself changes
    *both* the SUT and the input. Locking the fixture to a tag of
    the repo (e.g. `.bench-fixtures/swift-syntax-...`) is the
    standard discipline.
- **CI does not gate on regression.** The summary step
  (benchmarks.yml:54-76) builds a markdown table and posts it as a
  PR comment. There is no baseline JSON, no per-scenario threshold,
  no `gh pr review --request-changes` if `wallSecondsMean` rises by
  >X%. The README sentence "gated in CI" should be
  "reported in CI"; gating wants something like:
  ```yaml
  - run: |
      jq --slurpfile base baseline.json '
        .wallSecondsMean as $cur
        | $base[0].wallSecondsMean as $b
        | if $cur > $b * 1.10 then exit 1 else . end
      ' .bench/*.json
  ```
  with the baseline checked into the repo (or fetched from `main`
  via `gh run download`).

---

## Memory & cache findings

### `SoATokenStorage`

`Sources/SwiftStaticAnalysisCore/Memory/SoATokenStorage.swift`

- Column widths (line 102-115): `[UInt8] kinds`, `[UInt32] offsets`,
  `[UInt16] lengths`, `[UInt32] lines`, `[UInt16] columns`. Total
  13 bytes/token, sensible defaults.
- **UInt16 length cap of 65 535** is fine for tokens but tight for
  string literals; line 167 silently `min(length, UInt16.max)`s
  which means a single 64 KiB raw string literal is *truncated to
  65 535 bytes* with no diagnostic. Either widen `lengths` to
  `UInt32` or surface a length-overflow path.
- The columns are five separate `[T]` allocations. Cache-line aware
  would mean *interleaving* columns that are co-accessed in the hot
  loops. The clone-detection hot loops touch `(kind, offset, length)`
  together per token; storing them as a packed
  `[(UInt8, UInt32, UInt16)]` would actually be more cache-efficient
  than 3 separate columns for that access pattern. The current SoA
  layout is optimal for *kind-only* scans like
  `indicesWithKind(_:)` (line 256), which are not the hot path.
- `ArenaTokenStorage` (line 282) IS a proper SoA in raw buffers — good.
  Used by nobody in the duplication pipeline today; the duplication
  detector uses `SoATokenStorage` directly.
- **No `Span<UInt8>` / `Span<UInt32>` accessors** despite the README
  claim. The "Range Access" extensions return `ArraySlice<UInt32>`
  etc. (line 227+). `Span` would be the right API for Swift 6.2;
  `RawSpan` is wired into `MemoryMappedFile` (line 164) but not into
  the token columns.

### `Arena`

`Sources/SwiftStaticAnalysisCore/Memory/Arena.swift`

- `~Copyable` Arena with bump allocation: good (line 111).
- `alignment` validation (line 14): enforces power-of-two, correct.
- Default block size 64 KiB (line 25): reasonable. No mremap, no
  large-page hint.
- `reset()` (line 233) zeros the offset on every block, but never
  releases blocks back. For long-running MCP that means peak
  allocation persists. Worth adding a `release()` distinct from
  `reset()` (line 244 does that — good, just not wired up).
- `ThreadLocalArena` (line 384) uses raw `pthread_key_create` with
  `pthread_setspecific`. Each `withCurrent` call does at minimum a
  `pthread_getspecific` (cheap, ~5 cycles). Fine.
- **Stats counters update unconditionally** (line 263). They never
  get switched off in release; they're three Int writes per
  allocation. Not free.

### `MemoryMappedFile`

`Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift`

- `MAP_PRIVATE` (line 126), `PROT_READ` (line 125). Correct.
- `madvise(MADV_SEQUENTIAL)` (line 138) — sets the kernel's
  read-ahead pattern. For *line-range lookups* (which are random
  inside the file once the line-range table is built), `MADV_RANDOM`
  would be better after the first scan. Currently `MADV_SEQUENTIAL`
  is set once at init.
- `O_NOFOLLOW` on Darwin (line 68) — good defence-in-depth.
- `S_IFREG` check (line 105) — good.
- 256 MiB cap (line 60) — reasonable.
- `findLineRanges` (line 241) memoises behind `Mutex` — good. The
  scan is `for i in 0..<size where data.load(...) == 0x0A` — a
  per-byte `load(fromByteOffset:)`. The fast path on Apple Silicon
  is `vmaxvq_u8 == 0x0A` over 16-byte chunks. With `RawSpan` you
  could pull the bytes into a `simd_uchar16` and `vceqq_u8(byte,
  0x0A)` 16 bytes at a time. The current loop is the dominant cost
  of `findLineRanges` on multi-MB files.
- `findLineRanges` returns `[(offset: Int, length: Int)]` — a fresh
  `[(Int, Int)]` allocation that's typically *larger than the file
  itself* (each entry is 16 bytes; a 1000-line file with 50-char
  lines is 50 KiB of source, 16 KiB of ranges). For the common case
  where the only use is `line(_:)`, two parallel `[UInt32]` columns
  would halve memory.

### LRU caches

- `SwiftFileParser.cache` is `OrderedDictionary<String, CachedParse>`
  (Sources/SwiftStaticAnalysisCore/Parsing/SwiftFileParser.swift:152)
  with `cacheLimit: Int = 256` (line 29).
- `ZeroCopyParser.cache` is the same, with `cacheLimit: Int = 64`
  (Sources/SwiftStaticAnalysisCore/Memory/ZeroCopyParser.swift:134).
- Both are O(1) per touch via `OrderedDictionary.removeValue + insert`
  (good — replaces the prior `[String: CachedParse] + [String]`).
- **FD awareness**: ZeroCopyParser keeps a `MemoryMappedFile` per
  entry, each holding an open `fd`. With cacheLimit=64 and an
  ulimit of 256, you have headroom for IndexStoreDB (which opens
  many fds itself) but a tighter env (CI containers default to 1024
  ulimit but `xcrun` and `swift build` can chew through it) could
  starve. Worth surfacing as a config.
- **No size-aware eviction.** A small file and a 250 KiB file count
  equally toward `cacheLimit`. For a single-file 100 MB Swift Package
  manifest, this is OK; for very heterogeneous corpora a byte-budget
  eviction would be more memory-predictable.

### Bitmaps

- `AtomicBitmap` boxed atomics — see SOTA section above.
- `Bitmap` (non-atomic) is hand-rolled at
  `Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift:174`.
  `swift-collections` 1.1's `BitArray` is API-equivalent for the
  non-atomic case and is maintained by Apple. Migration would be ~50
  LoC.
- `popCount` uses `nonzeroBitCount` (line 261) — stdlib's POPCNT
  intrinsic. Correct.
- `forEachSetBit` uses `trailingZeroBitCount` + `word &= word - 1`
  (line 268-275). Correct, standard BSF/`ctz` lowering.

---

## Concurrency findings

### TaskGroup granularity

- `ParallelFrontierExpansion.expandParallel`
  (`Sources/SwiftStaticAnalysisCore/Algorithms/ParallelFrontierExpansion.swift:26`)
  chunks the frontier into `frontier.count / maxConcurrency` slices.
  Coarse-grained, good. Cancellation propagation at line 62 is via
  `group.cancelAll()` — correct fix from the 0.1.x audit.
- `ParallelVerifier.verifyCandidatePairs`
  (`Sources/DuplicationDetector/Parallel/ParallelVerification.swift:63`)
  chunks by `pairs.count / maxConcurrency`. Threshold-gated at
  `minParallelPairs: Int = 100` (line 38), reasonable.
- `LSHIndex.findCandidatePairsParallel` (LSH.swift:233) chunks by
  bands. For a typical `b = 32, r = 4` config you get 8 chunks on an
  8-core machine — good.
- `MinHashCloneDetector.detect` (line 127) on the non-parallel path
  *does not parallelise the per-file shingling pass* (line 135–143
  is sequential). For 100k files that's the dominant cost. The
  parallel variant `detectParallel` (line 197) parallelises
  signature computation but still shingles serially (line 204-212).
  Easy win: parallel-shingle then merge into `documents`.

### Backpressure

- The "real backpressure" path is `BackpressuredChannelStream`
  (`Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift:69`).
  Used by:
  - `StreamingVerifier.streamResultsBackpressured`
    (`ParallelVerification.swift:400`) — wired.
  - `LSHIndex.findCandidatePairsStreaming` (LSH.swift:270) — *not
    wired*; this still uses `TaskBackedAsyncStream.bufferingNewest`,
    which is buffer-and-drop, not backpressure.
- The implementation itself
  (`TaskBackedAsyncStream.swift:80`) spawns a background `Task` and
  does **not** propagate task cancellation back from the channel
  consumer. The `defer { continuation.finish() }` pattern is in the
  *consumer* of `BackpressuredChannelStream`'s closure, but if the
  caller stops iterating, the producer doesn't know; the `AsyncChannel`
  will indefinitely await `send`. This is technically a latent leak.
  Compare to `AsyncStream`'s `onTermination` hook used in
  `TaskBackedAsyncStream.makeStream` (line 42).

### Atomic memory ordering

- `AtomicBitmap` uses `.relaxed` everywhere
  (Bitmap.swift:71, 89, 104, 115, 125, 150, 158). For BFS visited
  tracking this is correct — within one BFS *iteration*, the
  consumers don't read what producers wrote (they only test-and-set
  their own bit), and between iterations the `TaskGroup` join is the
  synchronisation point. The `await` in `for await partial in group`
  is an acquire fence.
- However `popCount` (line 112) reads all words with `.relaxed`,
  and the docstring at line 109 admits "result is consistent only
  within each word". For BFS direction-switching that's fine
  (heuristic). For any caller using `popCount` as a correctness
  signal it isn't. Caller-side: `DenseGraph.remainingEdges(visited:)`
  uses `visited.test(i)` (line 145) word-by-word; the inconsistency
  doesn't affect correctness because BFS only ever sets bits, never
  clears.

### Actor vs Mutex split

- `ReachabilityGraph` is an `actor` (ReachabilityGraph.swift:176).
- `IndexBasedDependencyGraph` is a `class` with `Mutex` (line 154,
  321), justified by IndexStoreDB's non-`Sendable` callbacks. Clear
  rationale in the docstring. Reasonable.
- `SwiftFileParser` and `ZeroCopyParser` are actors. Fine.
- **Re-entrancy risk**: actor methods that call out via
  `withCheckedContinuation` could lose isolation; none of the code
  here does that.

---

## Benchmark methodology critique

(Mostly covered in "Algorithmic findings #9 — swa-bench methodology"
above.) Concise summary:

| Aspect | State | What SOTA looks like |
|---|---|---|
| Warmup iterations | 1 | 3–5 |
| Measured iterations | 3 | 10–20 with timeout per scenario |
| Stat reported | mean/min/max | median + p99 + stddev |
| Cold-cache | not measured | separate scenario |
| CPU pinning | none | `taskset` on Linux; macOS has no equivalent |
| Fixture | repo's `Sources/` (self) | pinned external corpus |
| Regression gate | none — only PR comment | hard threshold or % delta vs baseline JSON |
| Baseline storage | none | committed `benchmarks/baseline.json` updated by maintainer |
| Memory measurement | peak RSS (good) | peak RSS + page-faults |
| Variance handling | none | repeat scenarios that varied >10% |

Recommended minimal change: add a `--baseline path.json` flag to
swa-bench that exits non-zero if any scenario regresses by >10%
mean-wall, and commit a baseline JSON per fixture under
`benchmarks/baselines/`. Update via a maintainer-only label on PRs.

---

## Missed Apple / Swift native API perf opportunities

1. **`Span` / `RawSpan` adoption.** Wired into `MemoryMappedFile`
   (`withRawSpan` at line 164) and `FileSlice` (line 412) but no
   downstream consumer uses it. The `SoATokenStorage` accessors
   return `ArraySlice<…>` (line 227–243) — switching to `Span<UInt8>`
   etc. would let the compiler elide bounds checks on the duplication
   inner loops.

2. **`InlineArray<N, T>` for fixed-size buffers.** Swift 6.2 has
   `InlineArray<128, UInt64>` (stack-allocated). The MinHash signature
   buffer (`MinHash.swift:187`) is the canonical use case. The
   `(heads, tails)` arrays in SA-IS bucket-boundary computation
   (`SuffixArray.swift:190`) are bounded by alphabet size and are
   prime candidates too.

3. **`swift-collections` `BitArray`.** The non-atomic `Bitmap`
   (`Bitmap.swift:174`) duplicates `swift-collections` 1.1's
   `BitArray`. Switching saves ~120 lines and gets the maintained
   implementation. `AtomicBitmap` can't switch (no atomic flavour
   upstream), but the non-atomic one can.

4. **`swift-collections` `Deque`.** Already used in
   `MinHashCloneDetector.findConnectedComponents` (line 404) and
   `ReachabilityGraph.findPathFromRoot` (line 370). Good. But
   the SCCP worklist `[CFGEdge]` (line 279) and ReachingDefinitions'
   `Set<BlockID>` worklist would benefit from `Deque` too.

5. **`Accelerate` / `simd` framework.** Already used in MinHash
   SIMD4 path. The line-range scan in `MemoryMappedFile.findLineRanges`
   (line 250) is an ideal `simd_uchar16`/`vceqq_u8` candidate —
   16-byte chunks instead of per-byte loads. So is the
   `hashRange`/`rangesEqual` SoA loop (SoATokenStorage.swift:475,
   488).

6. **`os_signpost` / `OSLog`.** No signposts in the codebase. For a
   perf-engineered framework these are free and let users profile
   in Instruments without rebuilding. Worth wrapping the BFS step,
   MinHash signature pass, and SA-IS recursion.

7. **`mmap` `MADV_RANDOM` after first line-range scan.** As noted
   above. Two `madvise` calls: `MADV_SEQUENTIAL` at init (read-ahead
   the full file once), `MADV_RANDOM` after `findLineRanges` returns
   (subsequent reads are line-indexed).

8. **`fadvise64`-style read-ahead via `posix_fadvise(POSIX_FADV_WILLNEED)`**
   on cold-start could shave first-iteration time on a multi-GB
   codebase. Currently nothing prefetches.

9. **Compression framework**: not relevant for static analysis hot
   paths. Cache-on-disk (`AnalysisCache`) currently uses JSON;
   switching to `Compression`-backed binary plist or
   `swift-serialization` could shrink incremental caches. Not a
   perf-critical path.

10. **`CMSimd` / `_Builtin_intrinsics`**: not exposed to Swift today
    in a stable way; skip.

11. **`Distributed` actors**: not relevant here.

12. **IndexStoreDB**: the codebase uses the same upstream as
    SourceKit-LSP — good. The N+1 fix in 0.2.0
    (`IndexStoreAnalyzer.analyzeUsage` per CHANGELOG) is the right
    move. The remaining gap vs SourceKit-LSP is that LSP's
    incremental update path uses `IndexStoreDB.NotificationDelegate`
    to react to changes; this codebase rebuilds the index graph from
    scratch on every invocation (`IndexBasedDependencyGraph.build`,
    line 195: `nodes.removeAll(); edges.removeAll(); …`).
    Long-running MCP sessions on a slowly-changing project pay the
    full build cost on every query. SourceKit-LSP avoids that.

13. **SCIP / LSIF**: the codebase exports its own JSON format. SCIP
    (Sourcegraph, 2023) is the open standard for *cross-tool* symbol
    indexes. If "symbol lookup" output were also SCIP-emitting, the
    project could plug into Sourcegraph's perf-tuned UI for free.
    Not a runtime perf issue; ecosystem perf.

---

## Strengths — call them out

This codebase is *not* a toy. Specific perf engineering that is
genuinely well-done:

- **Mersenne-61 MinHash with hand-vectorised SIMD4 reduction.** The
  math is right, the choice is right, the lane width matches Apple
  Silicon's NEON 128-bit register width. The CHANGELOG description
  ("replaces the scalar unrolled-loop SIMD") is accurate.
  (`MinHash.swift:186`).

- **Direction-optimising parallel BFS faithful to Beamer et al.**
  Uses the *correct* heuristic (remaining edges, not total — a
  subtle point even some textbook implementations get wrong; see
  the docstring at `ParallelBFS.swift:202`). Defaults match the
  published paper. Sequential fallback for small graphs.

- **DenseGraph CSR projection with caching.** `denseGraphCache` is
  invalidated alongside `reachableCache` on every mutator
  (ReachabilityGraph.swift:218, 232; IndexBasedDependencyGraph.swift:485).
  Lazy build, single-pass. This is the right shape.

- **`AtomicBitmap` using stdlib `Synchronization.Atomic`.** No
  `swift-atomics` dependency; relaxed-ordering choice is
  *defensible* and *documented* (Bitmap.swift:71, 109).

- **`Mutex`-based serialisation of `findLineRanges`.** Single-shot
  cache, lock held only over the rare initial scan; subsequent calls
  read the cached value. Idiomatic `Synchronization.Mutex`
  (MemoryMappedFile.swift:316).

- **Bounded LRU parser caches via `OrderedDictionary`.** O(1) per
  touch, replaces the prior O(n) `firstIndex(of:)` pattern. Real
  improvement for long-running MCP. (SwiftFileParser.swift:152,
  ZeroCopyParser.swift:234).

- **Env allowlist for child processes.** Scrubbing
  `DYLD_INSERT_LIBRARIES` / `SWIFTPM_HOOKS_DIR` etc. before spawning
  is exactly right. Not a perf item but it's the kind of detail that
  signals the rest of the engineering is careful.

- **`~Copyable` Arena with TLS variant.** Compile-time enforcement
  of single-ownership is the modern Swift way to make a bump
  allocator safe. (Arena.swift:111).

- **`SoATokenStorage`** is real: five typed columns, byte-precise
  widths (UInt8/UInt32/UInt16/UInt32/UInt16). 13 bytes/token is the
  competitive number. The fact that it's not yet used everywhere
  it could be is the limiting factor, not the design.

- **AsyncChannel-backed `BackpressuredChannelStream`** is the right
  primitive to replace `bufferingNewest`-with-drop. The pattern is
  documented honestly: see the docstring at
  `TaskBackedAsyncStream.swift:21-25` which explicitly says
  "`.bufferingNewest` is buffer + drop oldest under overflow, not
  true backpressure". That kind of self-aware comment is rare.

- **`swa-bench` exists.** Even with the gating gap, having a
  reproducible bench binary with median/min/max + RSS is more than
  most Swift OSS packages ship.

- **Typed throws everywhere** (`throws(IndexStoreError)`,
  `throws(ConfigurationError)`, `throws(MemoryMappedFileError)`).
  Removes runtime existential boxing on the error path. Small but
  consistent perf win.

The pattern is: the *design* is mostly right, the *plumbing* is
half-done. The audit gap is closing the plumbing (default the
parallel BFS on large graphs, wire `BackpressuredChannelStream` into
the LSH candidate stream, port SA-IS to use `Arena`, adopt
`InlineArray<128, UInt64>` for signatures, gate the bench on a
checked-in baseline) rather than redesigning anything.

---

## Distance-from-SOTA scorecard

| Area | Current | SOTA | Gap |
|---|---|---|---|
| Type-1 clones (suffix array) | Pure-Swift SA-IS, correct, ~3-5× slower than libsais | libsais / divsufsort64 in C | Moderate. Wrap libsais via SwiftPM C target. |
| Type-2 clones (MinHash+LSH) | Mersenne-61, SIMD4, FNV banding | BBit-MinHash / DartMinHash / SuperMinHash for 4-8× smaller sigs at same accuracy | Moderate. Mostly accuracy/byte, not throughput. |
| Type-3/4 clones (AST fingerprint) | Polynomial hash mod 30-bit prime | SourcererCC bag-of-tokens + inverted-index filtering | Large. Different *family*. |
| Reachability BFS | Beamer direction-optimising on dense CSR | Same | Small. But not on by default. |
| Intraprocedural dataflow | Worklist on `Set<>` | Bit-vector dataflow, sparse on-demand | Moderate. Correct, but textbook implementation. |
| Symbol lookup | IndexStoreDB + SwiftSyntax resolvers | SourceKit-LSP (same lib) | Small. Same primitives; gap is incrementality (full rebuild per query). |
| Memory-mapped I/O | mmap + MADV_SEQUENTIAL + line-range memo | Same + MADV_RANDOM post-scan, SIMD newline scan | Small. |
| Token storage | SoA, 13 bytes/token, `[T]` columns | SoA on raw arena buffers via `Span` | Small. The `ArenaTokenStorage` type exists; just isn't used. |
| Bench / regression gating | Reports to PR, no gate | Baseline-diff with per-scenario threshold | Moderate. Easy to fix. |

Overall: a competent, ambitious second draft of a Swift-native
clone-and-dead-code detector. The biggest leverage points for the
next sweep are (a) closing the README/CHANGELOG ↔ code gaps so the
optimistic claims are actually backed; (b) wiring the existing
parallel/arena/SIMD primitives into the *default* call paths; and
(c) replacing the AST-fingerprint module with a SourcererCC-style
bag-of-tokens index for honest Type-3 recall.
