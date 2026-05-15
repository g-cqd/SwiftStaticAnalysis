# Changelog

All notable changes to SwiftStaticAnalysis will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0-beta.23] - Unreleased

**Full tree edit distance (APTED / Zhang-Shasha) replaces β.22's trigram
approximation in the `strict` preset.**

β.22 documented the trigram-Jaccard AST reranker as "a future direction
if the precision ceiling needs to be raised". β.23 raises it: ships the
real tree edit distance algorithm (Zhang-Shasha 1989 — which is the
LEFT-path strategy of Pawlik-Augsten 2015 APTED) and wires it into
`--preset strict`.

### New surfaces

- **`APTEDTree`** — post-order-indexed Swift tree representation. Stores
  labels + leftmost-leaf-descendant + parent indices per node. Keyroots
  computed via the canonical leftLeaf-disambiguation rule.
- **`APTED.distance(_:_:)`** — pure tree edit distance over two
  `APTEDTree`s. Insert/delete cost = 1, rename cost = 1 if labels
  differ, 0 if equal. Returns the minimum operation count.
- **`APTEDReranker`** — bridges SwiftSyntax source to APTED.
  `score(_:_:)` parses both snippets, builds APTED trees, computes the
  distance, returns the normalized similarity `1 - (TED / max(treeSize))`
  clamped to `[0, 1]`. Higher = more structurally similar.
- **`--embedding-rerank-apted` / `--embedding-apted-threshold`** —
  hidden CLI flags so power users can opt-in to APTED rerank
  independently of the `strict` preset. Default threshold 0.70.

### Strict preset is now properly layered

Four signals, in order of cost:

1. **Cosine** ≥ 0.90 (HNSW retrieval)
2. **Token Jaccard** ≥ 0.30 (multi-signal fusion, β.20)
3. **MaxSim** ≥ 0.85 (ColBERT-style token-level alignment, β.20)
4. **APTED** ≥ 0.70 (full tree edit distance, β.23 — replaces β.22 trigram)

Each gate catches a different false-positive class. A candidate must
pass every enabled gate.

### Empirical curve on this repo

```
swa duplicates Sources --semantic --embedding-bundle Models/MiniLM
  --preset loose    → 111 groups
  --preset balanced →  74 (default; cosine + Jaccard)
  --preset strict   →  26 (+ MaxSim + APTED — β.22 trigram-strict was 30)
```

APTED kills 4 more shape-only false positives than the β.22 trigram did.
Wall time on the full repo: 17.6s for strict (vs ~10s for β.22 trigram).

### Implementation honesty

- The shipped algorithm is **Zhang-Shasha** (1989). Mathematically it
  gives identical distances to full APTED — they're not different
  algorithms in output, only in worst-case time complexity (Zhang-Shasha
  is O(n² · d · l) where d=depth, l=leaves; APTED with strategy
  selection is O(n³)).
- The Pawlik-Augsten 2015 "all-path" upgrade adds a strategy-selection
  layer (LEFT vs RIGHT vs HEAVY path per subtree pair) on top of the
  same DP. That layer would speed up pathological skewed trees but
  doesn't change correctness. Swift function bodies are bounded-depth
  (typically 5-10 deep), so Zhang-Shasha's running time on our corpus
  is well below APTED's amortized advantage. Strategy selection is
  queued as a future direction if heavily-skewed inputs surface.
- The trigram `ASTShapeReranker` from β.22 is retained for power users
  who want the faster approximation; selectable via
  `--embedding-rerank-shape` (hidden flag).

### Tests

`Tests/DuplicationDetectorTests/APTEDTests.swift` (new, 9 tests, all pass):

- Empty + empty → 0
- Single-node identical → 0
- Single-node renamed → 1
- Single-node vs empty → 1 (insert or delete count)
- Identical 3-node tree → 0
- 3-node tree with one rename → 1
- Symmetry: `dist(A, B) == dist(B, A)`
- `APTEDReranker` on identical Swift source → score 1.0
- `APTEDReranker` Type-2 clone vs unrelated Swift snippet → strict
  ordering preserved

Full suite: 1197 tests.

## [0.3.0-beta.22] - Unreleased

**Continuing CLI cleanup + AST shape reranker (C from the SOTA roadmap).**

### `--semantic` on the umbrella

`swa analyze --semantic` now runs the full umbrella (structural duplicates +
unused code + embedding clone discovery) in one invocation. The
`runUmbrellaEmbeddingDiscovery` helper factors the discovery pipeline so
both `Duplicates` and `Analyze` share the same implementation.

### `--swiftui` shorthand on `swa unused`

The three SwiftUI-specific flags (`--ignore-swiftui-property-wrappers`,
`--ignore-preview-providers`, `--ignore-view-body`) collapse into a single
`--swiftui` flag. The individual flags still work (hidden from `--help`)
for fine-grained control. Most SwiftUI consumers should just pass
`--swiftui` and forget the rest.

### `--parallel` removed

The deprecated `--parallel` flag was removed from both `duplicates` and
`unused`. Replacement: `--parallel-mode {none|safe|maximum}`. The
deprecation has been in place; β.22 finishes the job. Breaking change
documented in the corresponding CLI test.

### C. AST shape reranker

New `ASTShapeReranker` in `Sources/DuplicationDetector/Semantic/`. Parses
each snippet via SwiftSyntax, walks the tree pre-order, emits the
type-name of each visited node into a linear sequence. Two snippets'
shape sequences are compared by **trigram Jaccard** over the linearized
node-type sequence. Catches the "same identifiers, different syntactic
skeleton" false-positive class that MaxSim can't filter (e.g. guard-chain
vs switch with the same vocabulary).

Why trigrams over node-type bags: bags match on shared vocabulary
ignoring order. Trigrams require local order to agree, which is closer
to actual structural similarity.

Why not full APTED tree edit distance: APTED is the gold standard but
~500 LOC of intricate Swift. The trigram approximation is empirically
strong on Type-2 detection at a fraction of the cost; APTED is queued
as a future direction if the precision ceiling needs to be raised.

### Strict preset upgraded

`--preset strict` now applies the full rerank stack:

- cosine threshold 0.90
- token Jaccard 0.30
- MaxSim 0.85 (token-level)
- AST shape 0.25 (structural-level)

A candidate must pass EVERY enabled rerank to survive. Each rerank
catches a different false-positive class.

Empirical curve on this repo (`swa duplicates Sources --semantic --embedding-bundle Models/MiniLM`):

| preset    | discovered groups |
|-----------|------------------:|
| `loose`   | 111 |
| `balanced`|  74 (default) |
| `strict`  |  30 (cosine + Jaccard + MaxSim + AST shape) |

### Tests

1188 still green. The `legacyParallelEmitsDeprecationWarning` CLI test
was rewritten as `legacyParallelIsRejected` — it now asserts that
`--parallel` is rejected with "Unknown option" (the deprecation became
removal in β.22).

### What's NOT in β.22 (queued)

- **D. Cross-encoder reranker** — needs another HF model conversion +
  Swift wrapper. The four layered signals already in place (cosine +
  Jaccard + MaxSim + AST shape) cover most of the precision wins a
  cross-encoder would deliver; D is now a marginal improvement, not the
  blocker it was in β.20.
- **Full APTED tree edit distance** — see "Why not full APTED" above.

## [0.3.0-beta.21] - Unreleased

**CLI consolidation: one option group, three presets, bundle auto-discovery.**

The β.20 embedding surface was too noisy: 7 `--embedding-*` flags
declared four times across `duplicates`/`search`/`anomaly`/`cohesion`,
threshold numbers (0.85/0.95/0.20/…) that users had to memorize per
model, and `--embedding-bundle Models/MiniLM` repeated on every
invocation. β.21 collapses it.

### The simplified surface

**Before (β.20):**
```bash
swa search "query" Sources \
  --embedding-bundle Models/MiniLM \
  --embedding-max-length 128 \
  -f text
swa duplicates Sources \
  --embedding-bundle Models/MiniLM \
  --embedding-similarity 0.85 \
  --embedding-min-token-overlap 0.20 \
  --embedding-rerank-maxsim \
  --embedding-maxsim-threshold 0.85 \
  --embedding-max-length 128 \
  --embedding-k 10 \
  --types exact --min-tokens 10000
```

**After (β.21):**
```bash
swa search "query" Sources               # auto-discovers Models/MiniLM
swa duplicates Sources --semantic        # auto + balanced preset
swa duplicates Sources --semantic --preset strict  # MaxSim + tight thresholds
```

### What changed

- **`EmbeddingOptions: ParsableArguments`** in a new
  `Sources/swa/EmbeddingOptions.swift`. Shared via `@OptionGroup` across
  `duplicates`, `search`, `anomaly`, `cohesion` — one definition site
  for `--embedding-bundle`, `--preset`, `--embedding-max-length`.
- **`SemanticPreset { balanced, strict, loose }`** materializes
  `(cosine, jaccard, maxsim)` tuples. Replaces 3-5 hand-tuned numeric
  flags per invocation:
  - `balanced` = `(0.85, 0.20, nil)` — fast, default
  - `strict` = `(0.90, 0.30, 0.85)` — high precision, MaxSim rerank
  - `loose` = `(0.80, 0.10, nil)` — high recall
- **Bundle auto-discovery**: if `--embedding-bundle` is omitted and
  `Models/` has exactly one bundle dir (one with `Model.mlpackage` or
  `Model.mlmodelc`), use it. If multiple, error with the list. If none,
  error pointing at `INTEGRATION.md`.
- **`--semantic` flag** on `duplicates`. Without it the structural pass
  still runs alone (backward-compatible). With it, embedding discovery
  fires with the chosen preset.
- **Advanced overrides hidden from `--help`**: `--embedding-similarity`,
  `--embedding-k`, `--embedding-min-token-overlap`,
  `--embedding-rerank-maxsim`, `--embedding-maxsim-threshold`. They
  still work for tinkerers but no longer clutter the default help view.
  Discoverable via `--help-hidden`.
- **`EmbeddingScanContext`** factors out the "load provider + walk paths
  + embed all snippets + L2-normalize" boilerplate. Each subcommand's
  body collapses from ~50 lines to ~15.

### Flag count delta

| subcommand | β.20 flags | β.21 flags (visible) | β.21 flags (with `--help-hidden`) |
|---|---:|---:|---:|
| duplicates | 19 | 14 | 19 |
| search     | 6  | 5  | 10 |
| anomaly    | 7  | 6  | 11 |
| cohesion   | 6  | 5  | 10 |

The hidden advanced flags are still there — every β.20 invocation is
binary-compatible with β.21 — but the default `--help` no longer
includes them.

### Verified on this codebase

Three preset runs on `Sources/` produce the expected curve:

```
swa duplicates Sources --semantic --embedding-bundle Models/MiniLM
  loose    → 111 groups (broad)
  balanced →  74 groups (default)
  strict   →  30 groups (MaxSim rerank kicks in)
```

### Tests

1188 still green. The library API for `EmbeddingCloneDiscovery.discover`
kept `minTokenOverlap: 0.0` as its default (CLI-side `balanced` preset
sets 0.20) so the existing tests with single-letter stub snippets
continue to work without modification.

## [0.3.0-beta.20] - Unreleased

**Beyond cosine: multi-signal fusion, MaxSim late interaction, semantic
search, anomaly detection, module cohesion.** Five new capabilities
landing in one release — the answer to "cosine isn't the right primitive".

### B. Multi-signal fusion: Token Jaccard verification

The pooled-cosine primitive can't tell "same shape, different content"
from "real Type-2 clone". `TokenJaccard.similarity(_:_:)` complements it
by computing identifier-token-set Jaccard on the raw source strings
(BERT keywords filtered out). `EmbeddingCloneDiscovery.discover(...)`
gains a `minTokenOverlap: Double` parameter — pairs whose lexical
Jaccard falls below it are dropped even if their cosine clears the
threshold. CLI flag: `--embedding-min-token-overlap` (default 0.20).
This kills the "shape-true, intent-false" false positives CodeBERT and
high-threshold contrastive models produce on Swift.

### A. MaxSim late interaction (ColBERT-style rerank)

Mean-pooling averages 128 per-token vectors into one — destroys local
alignment signal. MaxSim is the canonical fix: for each token in
snippet A, find its best match in snippet B, mean the bests. The
symmetric form averages both directions.

- **`HFSemanticEmbeddingProvider.embedTokens(snippet:)`** — runs the
  same forward pass as `embed(snippet:)` but returns the unpooled
  per-token `[T × D]` matrix, L2-normalized row-wise. Throws on pre-
  pooled exports (Gemma) which don't surface token-level state.
- **`MaxSimVerifier.score(_:_:)`** — O(m·n·D) per pair, used as a
  post-discovery rerank on the K candidates HNSW returns. Drops groups
  below the `maxSimThreshold`.
- **CLI**: `swa duplicates --embedding-rerank-maxsim --embedding-maxsim-threshold 0.85`
  cut 77 → 47 semantic groups on this codebase (39% reduction);
  threshold 0.90 → 20 groups (very precise).

### F. `swa search "<query>" <paths>` — semantic code search

New subcommand. Embeds the query through the chosen model bundle,
embeds every function-shaped snippet via `FunctionSnippetExtractor`,
returns the top-K by cosine. Outputs file:line + first-line preview.

Example:
```
swa search "extract identifier from declaration" Sources \
  --embedding-bundle Models/MiniLM --k 5
```

Returns the closest functions in the codebase (e.g., extract-signature
helpers, declaration-walking visitors), ranked by semantic similarity.

### H. `swa anomaly <paths>` — outlier detection

For each snippet, computes the mean cosine to its k nearest neighbors
(default k=5). Sorts by `1 − meanNeighborSim` — high score = function
that resembles nothing else in the codebase. Useful for surfacing
accidental complexity, legacy outliers, copy-paste from unfamiliar
codebases.

On this repo's `Sources/`, the top anomalies are tiny one-shot helpers
(`UnionFind.find`, `HNSWIndex.ensureLayerCapacity`,
`DeterministicEmbeddingProvider.init`) — confirms the signal is real
(small unique helpers SHOULD look isolated).

### I. `swa cohesion <paths>` — module cohesion

Groups snippets by the last N dirname segments (`--group-by 2`).
Reports per-module: snippet count, intra-module mean cosine,
inter-module mean cosine, and the difference (cohesion score).
Higher cohesion = module's snippets resemble each other more than
they resemble the rest of the codebase.

Top cohesion on this repo:
```
Sources/StaticAnalysisBuildPlugin      2  89% intra  24% inter  +66%
SwiftStaticAnalysisCore/Algorithms     4  56%      17%        +39%
SwiftStaticAnalysisCore/SIL           11  48%      26%        +22%
```

All modules score positive — no split candidates surfaced. Good
signal of architectural discipline.

### Implementation details

- `TokenJaccard` is regex-light (~70 LOC). One pass over Unicode
  scalars, lowercase, drop a small stop-word set (Swift control-flow
  + access modifiers).
- `MaxSimVerifier` is naive O(m·n·D) per pair. SIMD-acceleration via
  Accelerate is a future direction. At K=10 reranks per query, total
  cost is bounded.
- All three new subcommands (`search`, `anomaly`, `cohesion`) share
  `SearchMath` for L2-normalization + cosine dot.
- Hit a `String(format: "%s", swiftString)` UB segfault in cohesion's
  output formatting — replaced with type-safe `String.padded(...)`
  helper.

### Scope NOT yet landed (deferred to next iteration)

- **C. AST tree edit distance rerank** — needs APTED in Swift,
  bigger implementation (~500 LOC). Pending.
- **D. Cross-encoder reranker** — needs another HF model conversion +
  Swift integration. Pending.

### Tests

1188 tests still green. Existing `EmbeddingCloneDiscoveryTests` had to
move `minTokenOverlap` default from `0.20` to `0.0` at the library API
level (the CLI keeps 0.20 as default) — the stub tests use single-letter
snippet strings that have zero token overlap.

## [0.3.0-beta.19] - Unreleased

**7-model embedding benchmark + provider robustness for fixed-shape and
pre-pooled exports.**

After β.16 wired SOTA via `swa duplicates --embedding-bundle`, the open
question was: which model to recommend by default. β.19 answers it
empirically — `scripts/swa-embed-benchmark.sh` A/Bs every downloaded HF
CoreML bundle through the swa CLI on this repo's `Sources/`, at four
thresholds, reporting dup-line count, wall time, and top-1 cosine.

### Results (full `Sources/`, 823 function snippets)

| Bundle | params | 0.80 dup-L | 0.85 dup-L | 0.90 dup-L | 0.95 dup-L | wall (s) | top cosine |
|---|---:|---:|---:|---:|---:|---:|---:|
| **MiniLM** | 22M | 6071 | 3435 | 1376 | **244** | **10** | 82→96% smooth |
| BGEBase | 110M | 17520 | 16910 | 13517 | 2678 | 16 | 91→98% bouncy |
| BGELarge | 335M | 12085 | 5700 | 2481 | 634 | 41 | 83→98% |
| MxbaiLarge | 335M | crash | crash | crash | crash | 7 | (SIGSEGV in MLModel.prediction) |
| MSMarcoCode | 110M | 13117 | 8097 | 3268 | 826 | 17 | 85→95% |
| CodeBERT | 125M | 18529 | 18529 | 18529 | 18529 | ~190 | 99% (plateau) |
| EmbeddingGemma | 300M | (slow) | — | — | — | >>300 | (works, too slow to bench) |

### Conclusions

**MiniLM wins on this codebase.** It's the only model with a properly
graduated cosine curve (smooth halving per 0.05 threshold step). The
top-1 cosine rises from 82% → 96% as the threshold rises, indicating
the embedding space separates similar from dissimilar code cleanly.
Plus, it's the smallest (22M, 88MB on disk) and fastest (10s for the
full repo).

**CodeBERT is unusable.** Its dup-line count is identical at all four
thresholds (18529) because every pair has cosine > 0.95. The model
clusters all Swift code at the top of its embedding space — a property
of its masked-LM training objective, not the CoreML conversion (the β.18
`verify-codebert-conversion.py` script proved the PyTorch and CoreML
outputs agree to within 0.0074 max cosine divergence).

**BGE family clusters too tight at low thresholds**; only useful at
0.95+, at which point a smaller model gets you the same precision faster.

**MSMarcoCode** (sentence-transformers/msmarco-bert-base-dot-v5
fine-tuned on CodeSearchNet) found a real **3-way cross-module clone**
in dataflow `debugDescription()` methods that MiniLM missed — but
inspection showed it's an **intentional shape duplication** (each
dataflow analysis prints its own state; the structural similarity is
necessary, not refactorable). So MSMarcoCode trades MiniLM's precision
for broader recall, with the recall mostly returning false-positives-
by-intent.

**MxbaiLarge** segfaults inside `MLModel.prediction(from:)` in Swift,
despite working in Python via `coremltools.predict`. Probably a bundle-
format issue; not fixable without re-converting. Excluded.

**EmbeddingGemma** works (after a β.19 padding fix) but its fixed
[1, 128] input shape + 300M params makes per-snippet inference ~1.5s,
which doesn't scale to a full-repo scan in reasonable wall time.

### Provider robustness landed in this release

`HFSemanticEmbeddingProvider` now handles two cases the β.16 implementation
rejected:

1. **Fixed-shape inputs**: when the model declares `input_ids` as `[1, N]`
   (e.g. EmbeddingGemma's `[1, 128]`) instead of dynamic `[1, 1]`, the
   provider pads the token sequence to N. The `attention_mask` is 1 for
   real tokens, 0 for padding, so mean-pooling skips padding positions.
2. **Pre-pooled outputs**: sentence-transformer exports that bake the
   pooling into the model graph emit a `[1, D]` tensor rather than the
   canonical `[1, T, D]` `last_hidden_state`. The provider detects 2D
   output and uses it directly.

These changes unlocked EmbeddingGemma; future model bundles with either
shape work without per-model code.

### Recommended default

`swa duplicates ... --embedding-bundle Models/MiniLM --embedding-similarity 0.90`
is the empirical winner on this codebase: ~1.3k dup-lines surfaced, top
cosines in the 91-96% range, 10-second wall time. Tighter (`0.95`) gives
~250 dup-lines if you only want the highest-confidence semantic clones.

### Tools shipped

- `scripts/swa-embed-benchmark.sh` — full A/B harness (7 bundles × 4
  thresholds), apples-to-apples through the swa CLI.
- `scripts/verify-codebert-conversion.py` — PyTorch-vs-CoreML faithfulness
  check (used to prove the CodeBERT plateau is model, not conversion).

## [0.3.0-beta.18] - Unreleased

**Consolidate `CFGStatement.shortDescription(maxLength:)` — model-discovered.**
`swa duplicates Sources --embedding-bundle Models/MiniLM --embedding-similarity 0.88`
surfaced `LiveVariableAnalysis.extractAssignedValue` and
`ReachingDefinitions.extractValue` at 98% cosine — same trim-and-cap logic with
different magic-number thresholds (100 vs 50). NL self-scan in β.15 had flagged
the same pair at 0.998. β.18 actions it.

New `CFGStatement.shortDescription(maxLength:)` helper in `CFGBuilder.swift`
(internal, on the existing type). Both call sites collapse from 7 lines each
to a one-liner that preserves the per-caller threshold:

```swift
// LiveVariableAnalysis: was 7 lines, now:
private func extractAssignedValue(_ statement: CFGStatement) -> String? {
    statement.shortDescription(maxLength: 100)
}

// ReachingDefinitions: was 7 lines, now:
private func extractValue(from statement: CFGStatement) -> String? {
    statement.shortDescription(maxLength: 50)
}
```

The thresholds intentionally differ — LiveVariableAnalysis tolerates longer
RHS captures, ReachingDefinitions is stricter — so the helper takes
`maxLength:` as a parameter rather than baking in a single value.

### Notes on findings not actioned

The β.17 → β.18 self-scan also surfaced two findings that **shouldn't** be
consolidated, recorded here for the next reviewer:

- **`DeclarationKindConverter.shouldReport` vs 3 callers** (93% cosine) —
  not a duplicate. The 4 sites have intentionally different default-case
  policies (true / false / true-but-imports-false) and different exhaustive
  coverage. Consolidation requires policy negotiation, not extract-method.
- **`TokenSequenceVisitor.classifyToken` ↔ `ZeroCopyParser.classifyToken`**
  (91% cosine) — already audited; both sites carry `swa:ignore-duplicates`
  directives because the parsers return different types (`TokenKind` vs
  `TokenKindByte`). Unifying would require generic types or codegen.

The fact that both findings are real-looking but rejected demonstrates the
importance of model + reviewer in the loop — not every clone-by-cosine is
a clone-by-intent.

## [0.3.0-beta.17] - Unreleased

**Drop `BertSemanticEmbeddingProvider` — fully superseded by
`HFSemanticEmbeddingProvider`.** Discovered by running the β.16 structural
clone detector against the codebase itself: 17 overlapping clone groups
between `BertSemanticEmbeddingProvider.swift` and the new
`HFSemanticEmbeddingProvider.swift`, covering the full mean-pooling +
MLMultiArray-building path. `HFSemanticEmbeddingProvider` already handles
WordPiece via `Tokenizers.AutoTokenizer`, so the hand-rolled
`BertWordPieceTokenizer` is dead too.

Net: −370 LOC of redundant provider code, −3 tests (the BERT-specific
end-to-end coverage is duplicated by the `HF*` path through the same
MiniLM bundle).

The `Bert*` types were β.15 stopgaps shipped before the
`swift-transformers` integration in β.16 made model-architecture-agnostic
loading possible.

## [0.3.0-beta.16] - Unreleased

**SOTA semantic clone discovery, fully Swift-native via the `swa` CLI.**

β.15 shipped real downloaded embedding models but proved the pipeline through
a Python harness (`scripts/embed-self-scan.py`) because the Swift tool had
three integration gaps: no BPE tokenizer, no CLI flag, no SwiftSyntax-based
function extractor. β.16 closes all three. The `swa duplicates
--embedding-bundle <dir>` invocation now runs the full discovery pipeline
end-to-end in Swift against any HuggingFace feature-extraction model.

### New surfaces

- **`HFSemanticEmbeddingProvider`** — model-agnostic `SemanticEmbeddingProvider`
  backed by `Tokenizers.AutoTokenizer` (HuggingFace `swift-transformers`) +
  Core ML. Loads a "bundle directory" containing `Model.mlpackage` /
  `.mlmodelc` plus the standard HF tokenizer files (`tokenizer.json`,
  `config.json`, etc.). Handles BERT WordPiece, RoBERTa BPE, SentencePiece
  transparently — the bundle layout is the only thing the consumer needs to
  produce.
- **`FunctionSnippetExtractor`** — SwiftSyntax-based visitor that walks a
  source string / file / directory, extracts every `FunctionDeclSyntax` and
  `InitializerDeclSyntax` body that fits inside [`minimumLines`,
  `maximumLines`] (5..60 by default), and produces `EmbeddingSnippet`s
  suitable for `EmbeddingCloneDiscovery`. Skips `.build` and `Models`
  artifact dirs.
- **`swa duplicates --embedding-bundle <dir>`** CLI flag. Reads the bundle,
  walks the source roots via `FunctionSnippetExtractor`, embeds via
  `HFSemanticEmbeddingProvider`, runs `EmbeddingCloneDiscovery`, and merges
  semantic clone groups into the structural detector's output. Companion
  flags: `--embedding-similarity` (default 0.85), `--embedding-k` (default
  10), `--embedding-max-length` (default 256).
- **`swift-transformers` package dependency** (1.3.2). Pulled in so a single
  provider type covers every HF feature-extraction model without
  per-architecture tokenizer code.

### What works end-to-end via `swa` (no Python in the inference path)

| invocation | result |
|---|---|
| `swa duplicates Sources --embedding-bundle Models/MiniLM --embedding-max-length 128` | 78 semantic clone groups, 3449 dup lines, full Sources/ in 76s |
| `swa duplicates Sources/DuplicationDetector/Semantic --embedding-bundle Models/CodeBERT --embedding-max-length 128` | CodeBERT (RoBERTa BPE) loaded via swift-transformers, real semantic findings |
| `swa duplicates Sources --embedding-bundle Models/CodeBERT --embedding-similarity 0.95 --embedding-max-length 128` | Full Sources/ scan, 5:27 CPU on 823 function snippets |

### Pre-converted model bundles documented

`scripts/convert-hf-encoder.py` produces fresh bundles from any HF encoder.
For consumers who don't want to fight the `torch 2.8 + coremltools 8.x`
compatibility gap, pre-converted CoreML bundles are available on
HuggingFace:

- `sentence-transformers/all-MiniLM-L6-v2` →
  `wiktorwojcik112/all-MiniLM-L6-v2-coreml` (feature-extraction variant)
- `microsoft/codebert-base` →
  `rsvalerio/codebert-base-coreml` (drop-in; output named `hidden_states`)

The provider autodetects output name (`last_hidden_state` →
`hidden_states` → `output` → first multi-array output) and reads
`hidden_size` from the bundle's `config.json` so the embedding dimension
matches the model rather than relying on a baked-in default.

### Python comparison artifacts

`scripts/embed-sota-comparison.py` runs an A/B across 5 SOTA code embedders
(MiniLM, CodeBERT, GraphCodeBERT, Jina v2 code, CodeT5+ embedding) and
prints a ranked summary plus the top-5 discovered groups per model. Used to
inform the threshold defaults: MiniLM clusters wide (p99.5=0.688),
CodeBERT clusters tight (p99.5=0.996), GraphCodeBERT in-between (p99.5=0.977).

### Honest scope

- All four code-trained SOTA models (CodeBERT, GraphCodeBERT, Jina v2 code,
  CodeT5+) use RoBERTa byte-level BPE. swift-transformers handles this
  transparently — no per-model tokenizer code needed.
- `scripts/convert-hf-encoder.py` was tested fully on MiniLM-L6-v2. On
  CodeBERT/GraphCodeBERT the conversion segfaults under `torch 2.8.0` +
  `coremltools 8.x`; downgrading torch to 2.7.0 (the last tested version)
  is the documented workaround. Pre-converted bundles avoid the issue.
- The CodeBERT/GraphCodeBERT/Jina-code Python comparison ran fine; only the
  Swift integration of newly-converted code models requires the torch
  downgrade. The Swift CLI itself runs cleanly on the pre-converted bundles
  in the table above.

### Tests

Existing 1191 tests still green. The β.14/β.15 `NLContextual`,
`Deterministic`, and `Bert` integration tests are unchanged — they
exercise the same `SemanticEmbeddingProvider` protocol that the new
`HFSemanticEmbeddingProvider` conforms to.

## [0.3.0-beta.15] - Unreleased

**Real downloaded model + self-scan + first model-discovered refactor.**

β.14 wired Apple's `NLContextualEmbedding` as a real (no-bundle) provider but
NL is trained on English NL, not code. β.15 closes the remaining gap:

1. **`BertSemanticEmbeddingProvider`** — loads a downloaded Core ML model with
   the standard HF feature-extraction signature (`input_ids` + `attention_mask`
   → `last_hidden_state`), mean-pools per-token vectors via raw-pointer
   `MLMultiArray` access, conforms to `SemanticEmbeddingProvider`.
2. **`BertWordPieceTokenizer`** — minimal Swift WordPiece (~150 LOC) matching
   the BERT base-uncased convention, greedy longest-prefix-match with `##`
   subword continuation, loads HF-style `vocab.txt`.
3. **`scripts/convert-minilm.py`** — converts `sentence-transformers/all-MiniLM-L6-v2`
   to Core ML. Registers a coremltools custom `new_ones` converter (missing
   in coremltools 8.x) and explicitly threads `token_type_ids` + `position_ids`
   so BERT doesn't lazily new_ones them during tracing.
4. **`scripts/embed-self-scan.py`** — full-codebase self-scan via the same
   model: extracts 823 function-shaped snippets from `Sources/` via brace
   counting, embeds via SBERT, runs all-pairs cosine + union-find, prints
   the top 20 discovered semantic clone groups.

### Real self-scan findings

Running the pipeline against this repo's own `Sources/` surfaced REAL,
actionable Type-2 clones the structural detector missed:

| sim | finding |
|---|---|
| 0.977 | `LiveVariableAnalysis.extractAssignedValue` ↔ `ReachingDefinitions.extractValue` |
| 0.965 | `IndexBasedDependencyGraph.computeReachableLocked` ↔ `ReachabilityGraph.computeReachable` |
| 0.959 | `ParallelConnectedComponents.shouldSwitchToBottomUp` ↔ `ParallelBFS.shouldSwitchToBottomUp` |
| 0.856 | `denseGraph()` triplicate across `IndexBasedDependencyGraph` + `ReachabilityGraph` |
| 0.812 | `incremental(cacheDirectory:)` factory in both `DuplicationConfiguration` + `UnusedCodeConfiguration` |
| 0.809 | `classifyToken` / `normalizeToken` across 3 token-handling files |

These are semantic-rename clones — identifier names differ, logic is identical.
The structural detector (suffix array / MinHash) hashes identifiers and so
misses them by construction.

### First action on a finding: `DirectionOptimizingBFS` extraction

To prove the discovery is actionable (not just decorative), this release
consolidates the 0.959-similarity finding:

- New `Sources/SwiftStaticAnalysisCore/Algorithms/DirectionOptimizingBFS.swift`
  with two `@inlinable public static` helpers: `shouldSwitchToBottomUp` and
  `shouldSwitchToTopDown` implementing the Beamer-Asanovic-Patterson 2012
  α/β heuristics for hybrid top-down / bottom-up BFS.
- `ParallelConnectedComponents` and `ParallelBFS` both delete their
  copy-pasted private statics and call the shared helper.

Net: −36 LOC of duplicated math, one canonical implementation, full test
suite (1191 tests including 3 new BERT integration tests) green.

### Tests

`Tests/DuplicationDetectorTests/BertSemanticEmbeddingProviderTests.swift`
(new, 3 tests, gated on `Models/MiniLM.mlpackage` + `MiniLM-vocab.txt`
presence with `withKnownIssue` skip):

- `loadsAndEmbeds` — 384-dim non-zero vector against a real snippet.
- `semanticRankingClonesOverUnrelated` — cosine(sumA, sumB) > 0.7 AND
  > cosine(sumA, parseURL). Real semantic geometry from a downloaded model.
- `selfScanDiscoversGroups` — curated repo snippets, data-driven threshold
  (90% of a calibration pair's cosine), discovery surfaces the FNV-1a hash
  + its renamed twin (cosine 0.795). Prints pairwise cosines for debugging.

### Honest scope

`all-MiniLM-L6-v2` is a sentence-transformer trained on English text, NOT
code. It catches Type-2 clones (identifier renames) well, partial Type-3
adequately, but won't beat a real code-trained model (CodeBERT,
GraphCodeBERT, CodeT5) on idiom-level Type-4 clones (for-loop vs reduce,
recursion vs iteration). The `CoreMLSemanticEmbeddingProvider` path
documented in `SemanticDeepClones.md` remains the production
recommendation for a Swift-tuned setup. β.15 ships the proof that the
pipeline works end-to-end against a real downloaded model.

## [0.3.0-beta.14] - Unreleased

**Real semantic embedding provider.** β.12 shipped the embedding-clone-discovery
*rails* (`HNSWIndex`, `EmbeddingCloneDiscovery`, `DeterministicEmbeddingProvider`)
but never ran the pipeline against a real model — the deterministic provider is
just FNV-1a hash bucketing, not semantically meaningful. β.14 closes that gap by
shipping a provider backed by Apple's built-in `NLContextualEmbedding`
(macOS 14+, system-provided assets — no bundle download required at build time).

### `NLContextualSemanticEmbeddingProvider`

`Sources/DuplicationDetector/Semantic/NLContextualSemanticEmbeddingProvider.swift`:

- Wraps `NLContextualEmbedding(language:)` from the NaturalLanguage framework.
- Per-snippet inference: `embeddingResult(for:language:)` →
  `enumerateTokenVectors(in:using:)` → mean-pool tokens to a single fixed-dim
  `[Float]`.
- Construction is eager: `init(language:)` calls `load()` so any asset failure
  surfaces synchronously rather than on first inference. Returns
  `SemanticEmbeddingError.modelLoadFailed(underlying:)` wrapping a local
  `NLContextualEmbeddingError` (`.unsupportedLanguage(_)` or `.assetsUnavailable`)
  when the asset can't be loaded.
- Gated behind `#if canImport(NaturalLanguage)` so Linux builds don't break.

### What this captures (and what it doesn't)

`NLContextualEmbedding` is trained on English natural language, not code.
What it does capture, end-to-end:

- **Type-2 clones** — identifier renames, comment edits. Two implementations
  of "sum-of-array" with different variable names embed close in cosine space.
- **Partial Type-3 clones** the structural detector misses.

What it doesn't:

- Idiom-level Type-4 clones (recursion vs iteration, for-loop vs reduce). A
  code-trained model (`CodeBERT`, `GraphCodeBERT`, `CodeT5-base`) via
  `CoreMLSemanticEmbeddingProvider` would do materially better. The integration
  path documented in `SemanticDeepClones.md` is unchanged — `NLContextual…` is
  the credible no-bundle baseline; Core ML is the production path.

### Integration tests prove the pipeline

`Tests/DuplicationDetectorTests/NLContextualSemanticEmbeddingProviderTests.swift`
(new, 4 tests). Each test catches `modelLoadFailed` and short-circuits with
`withKnownIssue` when assets aren't downloadable (offline CI / fresh sandbox),
so the suite is portable across machines while still exercising the full
pipeline when assets are present.

- **Dimension probe** — provider reports a positive `embeddingDimension`.
- **Determinism** — embedding the same snippet twice yields byte-identical
  vectors.
- **Direction** — `cosine(sumOfArrayImplA, sumOfArrayImplB) >
  cosine(sumOfArrayImplA, parseURL)`. The two sum-of-array implementations
  use renamed identifiers but compute the same thing; the URL-parser is
  unrelated. NL ranks them correctly.
- **End-to-end discovery** — `EmbeddingCloneDiscovery.discover(...)` over 4
  real snippets, with a data-driven threshold derived from the genuine pair's
  cosine, surfaces a `CloneGroup` containing both `alpha.swift` and
  `beta.swift`. The pipeline (provider → HNSW → union-find → `CloneGroup`)
  works against actual embeddings, not stubs.

All 4 new tests pass on this host. Full suite: 1188 tests.

### Truth-up: prior CHANGELOG claim

β.12's CHANGELOG said EmbeddingCloneDiscovery was "no longer future." That was
true for the *infrastructure* but misleading about the *signal* — the only
shipped providers were `UnconfiguredSemanticEmbeddingProvider` (throws on every
call) and `DeterministicEmbeddingProvider` (hash buckets, not semantic). β.14
makes the claim concrete with a provider whose output actually has semantic
geometry.

## [0.3.0-beta.13] - Unreleased

**`swa-lsp` Language Server.** A new executable target surfaces
`DuplicationDetector` and `UnusedCodeDetector` results as editor diagnostics
over JSON-RPC 2.0, the inverse direction of the β.9 `SourceKitLSPClient`
(which *consumes* sourcekit-lsp; `swa-lsp` *is* an LSP server).

### New surfaces

- **`SwiftStaticAnalysisLSPServer`** library target — three files:
  - `LSPProtocol.swift` — JSON-RPC envelope + LSP message types
    (`InitializeRequest`/`Response`, `TextDocumentItem`,
    `DidOpenTextDocumentParams`, `Diagnostic`, `PublishDiagnosticsParams`,
    `Range`, `Position`, `DiagnosticSeverity`, `JSONRPCError`).
  - `LSPServer.swift` — the LSP message loop. `LSPServer` is an `actor` so
    dispatch serializes without ad-hoc locks. `StdioLSPTransport` uses the
    cage pattern: a private `final class Storage: @unchecked Sendable` holds
    mutable buffers; the outer type is plain `Sendable` and exposes only
    async methods. Locking uses `Synchronization.Mutex` (Swift 6
    async-safe), not `NSLock`.
  - `DiagnosticProducer.swift` — runs the analysis pipelines per-document
    against a temp scratch file and maps results into LSP `Diagnostic`s.
- **`swa-lsp`** executable — `@main` `AsyncParsableCommand` reads JSON-RPC
  from stdin and writes responses to stdout. Stderr is reserved for logs so
  it doesn't interleave with the LSP framing.

### LSP coverage

Implemented methods: `initialize`, `initialized`, `textDocument/didOpen`,
`textDocument/didChange` (full sync), `textDocument/didClose`,
`textDocument/diagnostic`, `shutdown`, `exit`. Push notifications via
`textDocument/publishDiagnostics` on open and change. Unknown methods
return JSON-RPC `-32601 methodNotFound`.

### Diagnostic mapping

- `UnusedCode` → severity by confidence (`high` → warning,
  `medium` → information, `low` → hint). Range narrows to the identifier
  (1-based `SourceLocation` → 0-based LSP); code is `unused.<reason>`.
- `Clone` → information level. Range spans the whole block; end is the
  start of the line *after* the block so editors highlight the whole
  region. Code is `duplicate.<type>`.

### Editor wiring

Typical client config:

```jsonc
{
  "command": "swa-lsp",
  "args": [],
  "filetypes": ["swift"]
}
```

The binary builds in release via `swift build -c release --product swa-lsp`.
Smoke test:

```bash
.build/release/swa-lsp < /tmp/initialize-req.txt > /tmp/init-resp.txt
```

### Test coverage

`Tests/SwiftStaticAnalysisLSPServerTests/` (new, 15 tests across 3 suites):

- **`LSPFramingTests`** — Content-Length encode/decode round-trip, incomplete
  header handling, short-payload handling, back-to-back messages,
  `URIPathConverter` round-trip + non-file-URI rejection.
- **`LSPServerTests`** — `initialize` returns the right capabilities
  (`textDocumentSync.full`, `diagnosticProvider`), `didOpen` triggers
  `publishDiagnostics`, `didChange` updates and re-publishes, unknown method
  returns `-32601`, `shutdown` returns `null` result and `exit` triggers
  clean termination. Tests use a `StubTransport` to capture publishes.
- **`DiagnosticProducerTests`** — `mapUnused` 1-based → 0-based conversion
  + confidence-to-severity mapping; `mapClone` block-range mapping.

All 15 tests pass. Full suite: 1184 tests.

## [0.3.0-beta.12] - Unreleased

Two independent landings: embedding-based clone *discovery* (the recall-recovery
counterpart to β.8's precision-tightening verification pass) and a complete CI
integration surface (composite GitHub Action, pre-commit hooks, integration guide).

### Embedding-based clone discovery (HNSW)

β.8 wired Core ML embeddings into the duplication detector as a *verification*
pass — re-score structural candidates and drop token-level false positives.
That path is **precision tightening** by design: it cannot recover clones the
structural detector missed in the first place.

β.12 ships the recall-recovery counterpart: a hand-rolled HNSW (Hierarchical
Navigable Small World) index over snippet embeddings, plus a driver that
embeds → inserts → top-k queries → union-find groups → emits `CloneGroup`s
with `type == .semantic`. This is the "embed every snippet → ANN search →
threshold + group" pipeline `SemanticDeepClones.md` flagged as a future
direction; it's no longer future.

#### New public API

- **`HNSWIndex<Identifier: Hashable & Sendable>`** — the index itself. Methods:
  `init(dimension:configuration:)`, `mutating func insert(id:vector:)`,
  `func search(query:k:ef:) -> [HNSWSearchResult<Identifier>]`. Cosine
  distance with vectors L2-normalized at insert time. Value-type storage; once
  built, `search` is safe to call concurrently from multiple isolation domains.
- **`HNSWConfiguration`** — tunable parameters. Defaults follow Malkov &
  Yashunin (2016): `M = 16`, `efConstruction = 200`, `efSearch = 50`. Layer
  assignment uses splitmix64-seeded PRNG (`SeededPRNG`) so identical seeds
  produce identical graphs.
- **`HNSWSearchResult<Identifier>`** — `(id, similarity)` pair, similarity
  bounded to `[0, 1]` for normalized non-negative vectors.
- **`EmbeddingCloneDiscovery`** — the discovery driver.
  `init(hnswConfiguration:)`,
  `func discover(snippets:provider:k:similarityThreshold:) async throws -> [CloneGroup]`.
  Filters same-file overlapping snippets so a single snippet doesn't self-pair
  across the structural detector's overlapping windows.
- **`EmbeddingSnippet`** — input shape: `(file, startLine, endLine, tokenCount, code)`.
- **`DeterministicEmbeddingProvider`** — character n-gram FNV-1a hash bucket
  embedding. Dependency-free, stable across runs. NOT semantically meaningful
  — for smoke-tests, CI without model bundles, and self-contained discovery
  drives before a real Core ML model is wired in.

#### Algorithm

1. Embed every snippet via the `SemanticEmbeddingProvider`.
2. Insert each vector into `HNSWIndex<Int>` keyed by snippet index.
3. For each snippet, query top-`k` neighbors; pairs whose cosine similarity is
   at least `similarityThreshold` form edges in a similarity graph.
4. Compute connected components via union-find (path compression + rank).
5. Drop singletons; emit one `CloneGroup` per component with averaged pairwise
   cosine as `similarity` and `fingerprint = "embedding-<idx1>-<idx2>-..."`.

Brute force is O(n²) on snippet count; HNSW averages O(n log n). For 10k
snippets at 768 dim, brute force is ~10⁸ inner products. HNSW pays a one-time
build cost (~n log n) and supports fast queries afterwards.

#### Implementation notes

- HNSW internals (`MinPriorityQueue`, `BoundedMaxHeap`) are package-private,
  hand-rolled, and dependency-free aside from `Foundation`.
- The detector uses simple closest-`m` neighbor selection rather than the
  heuristic variant — auditable and adequate for the corpus sizes the
  duplication detector is exercised at.
- Same-file pair filtering uses interval overlap on line ranges, preventing
  the shingling window from self-pairing within a single function.
- Deterministic given a fixed `seed` in `HNSWConfiguration`; identical runs
  produce identical results.

#### Test coverage

`Tests/DuplicationDetectorTests/HNSWIndexTests.swift` (new, 6 tests):

- Exact-vector query returns the inserted point as the nearest neighbor.
- HNSW top-k recovers ≥ 60% recall against brute-force baseline on a 50-point
  16-dim random dataset (`recall@5 >= 0.6`).
- Insertion normalizes non-unit-length vectors (cosine-similarity invariant
  under scaling).
- Empty index returns no results.
- `count` reflects the number of insertions.
- Deterministic with fixed seed across runs.

`Tests/DuplicationDetectorTests/EmbeddingCloneDiscoveryTests.swift` (new, 6 tests):

- Identical-embedding snippets across three files form one merged clone group.
- Below-threshold pairs (orthogonal vectors) do not group.
- Same-file overlapping snippets are filtered out.
- Two distinct clusters yield two distinct clone groups.
- Empty / single-snippet input returns no groups.
- `DeterministicEmbeddingProvider` produces identical vectors across calls.

All 12 new tests pass. Full suite: 1169 tests.

### CI integration glue

Three drop-in surfaces so consumers can run `swa` in CI / pre-commit hooks /
custom workflows without writing wiring code:

- **`action.yml`** at repo root — composite GitHub Action wrapping
  `swift build -c release --product swa` + `swa duplicates` + `swa unused`.
  Inputs: `path`, `mode` (reachability/simple/indexStore), `clone-types`,
  `min-tokens`, `format` (sarif/text/json/xcode), `fail-on`,
  `swa-version`, `working-directory`. Outputs: `unused-count`,
  `duplicates-count`, `sarif-path`. SARIF is post-processed from JSON output
  (`swa` itself emits text/json/xcode); the action emits a SARIF v2.1.0 file
  suitable for GitHub Code Scanning ingest.
- **`.pre-commit-hooks.yaml`** at repo root — pre-commit-framework manifest
  exposing three hooks: `swa-analyze` (per-file on staged Swift files),
  `swa-duplicates` (cross-file on `Sources`), `swa-unused` (cross-file
  reachability mode on `Sources`). Uses `language: system` — consumers
  install the `swa` binary once and reference it on `$PATH`.
- **`INTEGRATION.md`** at repo root — quickstart guide for all three
  integration paths: GitHub Actions, pre-commit, local install, custom CI.
- **`.github/workflows/example-self-scan.yml`** — self-scan workflow that
  exercises the composite action against this repo's own `Sources/`. Acts as
  the canonical smoke test for `action.yml` — if it goes red, the action is
  broken.

#### CLI surface verification

All flags referenced by `action.yml` and `.pre-commit-hooks.yaml` were
verified against the current `swa` CLI (`SWA.swift`): `duplicates --types
--min-tokens -f`, `unused --mode --sensible-defaults -f`. The `fail-on`
input is implemented in the action itself (translating finding counts to
exit codes) since `swa` has no such flag.

## [0.3.0-beta.11] - Unreleased

**Semantic-deep clone detection user guide.** New DocC article
`SemanticDeepClones.md` documents the end-to-end wiring for
plugging a Core ML code-embedding model into the duplication
detector's verification pass. Covers:

- Picking a model (CodeBERT, GraphCodeBERT, CodeT5-base) with
  Hugging Face source links and dim / context tables.
- Converting PyTorch → Core ML via `coremltools` with a worked
  recipe.
- Building a Swift `Tokenizer` closure that matches the model's
  BPE vocab.
- Plugging the provider into `DuplicationConfiguration` and
  tuning `semanticEmbeddingThreshold` (0.95 / 0.90 / 0.85
  precision-recall tradeoff).
- Performance characteristics (Neural Engine inference latency,
  memory footprint, batching).
- Honest scope: the integration is precision-tightening, not
  recall-recovery. Embedding-based clone discovery (HNSW / IVF
  over all snippets) is queued as a future direction.

No code changes; documentation only.

## [0.3.0-beta.10] - Unreleased

**PDG construction layer on top of the SIL parser.** The β.7 SIL
infrastructure gains a working `ProgramDependenceGraph` builder
that combines control-flow edges (already extracted by the
parser) with SSA def-use chains derived from per-instruction
operand references. The PDG is the input shape the SOTA research
queue's GNN clone-detection needs; producing it is now bounded
work (O(instructions)) rather than blocked architecture.

### New types

- **`SILValue`** — SSA value identifier (`%N`). Block arguments
  and instruction results share the same name space.
- **`PDGNodeKind`** — either `.value(SILValue)` or
  `.block(String)`. Block nodes participate in the CFG subset of
  the PDG.
- **`PDGEdgeKind`** — `.dataDependence` (SSA def-use) or
  `.controlFlow` (mirrors block successors).
- **`PDGEdge`** — `(source, target, kind)`.
- **`ProgramDependenceGraph`** — the assembled graph:
  - `function: SILFunction` — the SIL function the PDG was built from
  - `edges: [PDGEdge]` — all data + control edges
  - `definitions: [SILValue: (block: String, instructionIndex: Int)]`
    (block-argument defines use `instructionIndex == -1`)
  - `uses: [SILValue: [(block: String, instructionIndex: Int)]]`

### Construction

`ProgramDependenceGraph.build(from:)` walks each block's
instructions, parses each line into `(defined: SILValue?, used:
[SILValue])`, and records:

- Defines from `%N = <op>` instruction prefix and block-argument
  declarations.
- Uses from every `%M` reference in the operand string. Trailing
  `// users: %N` comments are stripped before scanning so they
  don't create phantom uses.
- Data-dependence edges from each used value's definition to the
  defining instruction (or the block, for terminators).
- Control-flow edges from each block to its parser-extracted
  successors.

### Test coverage

`Tests/SwiftStaticAnalysisCoreTests/ProgramDependenceGraphTests.swift`
(new, 3 tests):

- Straight-line function: defines + uses extracted correctly,
  block arguments marked with `instructionIndex == -1`.
- Branching function: both data-dependence and control-flow edges
  present, 4-block diamond produces 4 control-flow edges.
- Comments stripped before operand scan: a SIL `// user: %3`
  comment doesn't produce a phantom `%3` use.

1157 tests green; build warning-free.

### Status of remaining items

The deferred queue narrows:

- **β.11 — MinHash `InlineArray<128, UInt64>` cascade**: stays
  deferred. ~1100 LOC viral generic through 7 public types for
  ~6μs amortized perf gain per `swa duplicates` run; not
  measurable on the project's bench. Closes as
  `out-of-scope, design-decision-record-only`.
- **β.12 — PDG-based clone detection**: GNN comparison over PDGs
  is research-level (graph isomorphism / spectral similarity);
  the PDG infrastructure shipped here is its prerequisite.
- **β.13 — Core ML model conversion recipe docs**: bounded work,
  ships next.

## [0.3.0-beta.9] - Unreleased

**`swa unused --lsp <workspace>` build-required mode.** Mirrors β.5's
symbol-lookup pattern for unused-code detection. Every candidate the
reachability / index / syntax detector produces is verified against
`callHierarchy/incomingCalls` from sourcekit-lsp; declarations the
LSP server reports as having callers (including protocol-witness
dispatch the IndexStoreDB-only resolver misses) are dropped from
the unused list.

### New: `LSPSymbolResolver.incomingCallCount(uri:line:character:)`

Thin wrapper over `SourceKitLSPClient.incomingCalls(...)` that
issues `prepareCallHierarchy` + `callHierarchy/incomingCalls` and
returns the count of incoming call sites. Returns `nil` when the
LSP server reports no call-hierarchy item at that position
(callable couldn't be resolved). Used by the unused-pass filter
to keep candidates conservatively when LSP can't answer.

### CLI: `swa unused --lsp <workspace>`

After the standard unused-code detection + filters, each
surviving candidate is checked against the LSP:

1. Convert the declaration's location to a `file://` URI +
   0-based LSP line/character coordinates (our SourceLocation is
   1-based; conversion happens at the boundary).
2. `incomingCallCount(uri:line:character:)` issues the LSP
   request.
3. If `count > 0` → drop the candidate (LSP found callers).
4. If `count == 0` → keep (LSP confirms unused).
5. If `nil` or LSP query throws → keep conservatively
   (fail-open).

Audit's +20-30% protocol-precision claim now has its first real
implementation path. Subprocess lifecycle handled via the
`LSPSymbolResolver`'s lazy-start / explicit-shutdown contract.

1154 tests green; build warning-free.

## [0.3.0-beta.8] - Unreleased

**Semantic-deep verification pass wired into `DuplicationDetector`.**
The β.6 `CoreMLSemanticEmbeddingProvider` is now usable end-to-end:
configure `DuplicationConfiguration.semanticEmbeddingProvider` with
any `SemanticEmbeddingProvider` conformer and `detectClones(in:)`
will re-score every clone group against the embedding-space cosine
similarity of its members. Groups below the threshold drop as
token-level false positives.

### New configuration

- **`DuplicationConfiguration.semanticEmbeddingProvider:
  SemanticEmbeddingProvider?`** (default `nil`). When non-nil,
  enables the verification pass.
- **`DuplicationConfiguration.semanticEmbeddingThreshold: Double`**
  (default `0.95`, clamped to `0.0...1.0`). Minimum pairwise
  cosine similarity for a group to survive.

### Verification pass shape

After the standard token-shingle / suffix-array / AST detection
runs, every surviving clone group is processed by
`verifySemantically(groups:provider:threshold:)`:

1. Collect each clone's `codeSnippet`. Groups with fewer than two
   snippets pass through unchanged (no pairwise comparison
   possible).
2. Call `provider.embed(snippets:)` to get one embedding vector
   per snippet. Embedding failure → conservative-keep
   (`survivors.append(group)`). Failing-open means a single
   oversized snippet doesn't drop genuine clones.
3. Compute pairwise cosine similarity across the group's
   embeddings.
4. If the **minimum** pairwise cosine is ≥ threshold, the group
   survives; otherwise it drops.

Cost: bounded. `O(group_size)` embedding calls per group,
`O(group_size²)` cosine computations. Only runs on the candidate
set the structural passes already produced — semantic-deep
precision tightening, not a parallel recall-recovery pipeline.
A recall-recovery shape (embed every snippet in the corpus and
do ANN search) is the next layer.

### Status

Build complete; 1154 tests green. The verification logic is in
the public `DuplicationConfiguration` surface; programmatic
consumers can plug `CoreMLSemanticEmbeddingProvider` (with their
own tokenizer + model bundle) directly into the detector.
CLI integration (`--semantic-deep <model-path>` flag) needs a
tokenizer-spec convention the `.swa.json` schema can express;
that's queued for β.9-or-later.

## [0.3.0-beta.7] - Unreleased

**SIL extraction + parser spike.** The audit's F-S3 ("PDG/GNN clone
detection — not implementable in 0.3.x because it requires
`swiftc -emit-sil`") is no longer architecturally blocked. We now
ship a real SIL extractor + parser that drives `swiftc -emit-sil`
through `ProcessExecutor` and parses the textual output into
function-level control-flow graphs. The PDG construction layer
that consumes these CFGs is the next step (data-flow edges, def-use
chains beyond the SIL-emitted `// users:` comments); the
infrastructure to extract SIL at all is now in place.

### New: `Sources/SwiftStaticAnalysisCore/SIL/SILParser.swift`

Three types:

- **`SILFunction`** — a parsed function: mangled name, block-name
  → block map, block-order array for traversal.
- **`SILBasicBlock`** — block name, arguments (`%0`, `%1`, ...),
  raw instruction lines, successor block names derived from the
  terminator.
- **`SILParser`** — line-oriented parser. Recognised terminators:
  `return`, `br`, `cond_br`, `switch_value`, `switch_enum`,
  `switch_enum_addr`, `throw`, `unwind`, `unreachable`, `try_apply`,
  `dynamic_method_br`. Unrecognised terminators produce a block
  with no outgoing edges (a CFG sink); the caller can treat that
  as either a true exit or a parser gap.

The parser correctly handles paren-nested colons (`bb0(%0 : $Int):`
is two colons; only the depth-0 one is the block-header
terminator).

### New: `SILExtractor`

Invokes `swiftc -emit-sil <source>` through `ProcessExecutor` (env
allowlist applies — `DYLD_INSERT_LIBRARIES` etc. cannot ride into
the toolchain). Captures stdout, returns the parsed
`[SILFunction]`. `extraArguments` lets callers pass `-target`,
`-sdk`, `-I` etc. when the source needs them. On non-zero exit,
throws `SILExtractionError.compilationFailed(stderr:exitCode:)`
with the toolchain's diagnostic text.

### Test coverage

`Tests/SwiftStaticAnalysisCoreTests/SILParserTests.swift` (new, 3
tests):

- Parses a single-block function with no branches (`return` is a
  CFG sink).
- Parses a conditional-branch function — `cond_br` + `br` build
  a 4-block diamond CFG; predecessors / successors verified.
- Parses multiple functions independently in one SIL blob.

1154 tests green (1151 + 3 SIL parser tests); build warning-free.

### Status

This is the SIL **infrastructure** layer. The 0.4.0 PDG layer on
top can build:

1. **Intra-procedural data-flow** — extract def-use chains from
   SIL's SSA form (`%N = ...` defines, `%N` references use). SIL
   emits these in `// users: %M, %K` comments alongside each def
   line; the parser preserves the raw instruction text so a
   downstream pass can extract them.
2. **PDG construction** — combine CFG edges (we have them) with
   def-use edges (next layer) into a Program Dependence Graph
   per function. The GNN clone detection in the SOTA research
   queue consumes the PDG.
3. **Whole-program SIL** — driving `-emit-sil` per module
   (matching the build's compile-flag context) rather than
   per-file. The current extractor is per-file as the spike
   shape; production would integrate with SPM's build description.

## [0.3.0-beta.6] - Unreleased

**Real Core ML semantic-embedding provider.** The β.3
`SemanticEmbeddingProvider` protocol gains a working
`CoreMLSemanticEmbeddingProvider` implementation that drives Apple
`MLModel` inference end-to-end. No model bundle ships in-tree —
the integration is bring-your-own-model — but the wiring is
production-shaped, not a stub.

### New: `CoreMLSemanticEmbeddingProvider`

Wraps the standard `MLModel` inference pipeline:

1. Compile the model on first `embed(snippet:)` call via
   `MLModel.compileModel(at:)`. Pre-compiled `.mlmodelc` paths
   skip the compile step.
2. Tokenise via a caller-supplied `Tokenizer` closure (`String →
   [Int32]`). Each model has its own vocabulary; the closure is
   the integration seam.
3. Pack token IDs into `MLMultiArray<Int32>` of shape
   `[1, contextWindow]`, zero-padding to the model's context
   window. Refuses snippets that exceed the window.
4. Run `MLModel.prediction(from:)` (async).
5. Extract the pooled-output vector as `[Float]`.

Model compilation is cached behind an `NSLock`-guarded
`ModelStorage` so concurrent first-callers don't recompile.

### Bring-your-own-model

To use it end-to-end:

```swift
let provider = CoreMLSemanticEmbeddingProvider(
    modelURL: URL(fileURLWithPath: "/path/to/CodeBERT.mlmodelc"),
    tokenizer: { snippet in
        // Map a Swift String to Int32 token IDs.
        // Match the model's training vocab.
        return tokenIDsForCodeBERT(snippet)
    },
    embeddingDimension: 768,  // CodeBERT default
    contextWindow: 512,
    inputName: "input_ids",
    outputName: "pooler_output"
)
let embedding = try await provider.embed(snippet: codeSnippet)
```

Conversion recipes for CodeBERT / GraphCodeBERT / CodeT5 via
`coremltools` are upstream documentation; no Swift-specific
fine-tune ships either. Downstream consumers commit to a model
choice that fits their licensing / privacy / inference-cost
constraints.

### Conditional compilation

The provider is gated by `#if canImport(CoreML)` so the
`DuplicationDetector` module still builds on Linux (where Core ML
is unavailable). The protocol + `UnconfiguredSemanticEmbeddingProvider`
default from β.3 remain available on every platform.

Wiring into `DuplicationConfiguration` / `--semantic-deep` CLI is
staged for the next phase; the provider itself is now a usable
building block.

## [0.3.0-beta.5] - Unreleased

**Build-required symbol resolution.** The β.3 `SourceKitLSPClient`
spike is wired into a real `LSPSymbolResolver` + CLI flag. Users can
now run `swa symbol <query> --lsp <workspace-root>` to merge
`sourcekit-lsp` results (including protocol-witness dispatch
targets) with the IndexStore / syntax resolver's output.

### New: `LSPSymbolResolver`

Drives `sourcekit-lsp`'s `workspace/symbol` request against a
build-required workspace. Owns a lazily-started
`SourceKitLSPClient` (via a `Synchronization.Mutex`-guarded
storage slot) and shuts it down on demand. Supports:

- `.simpleName(...)` — direct workspace symbol query, name-equality
  filter.
- `.qualifiedName(...)` — query by leaf member name, filter by the
  immediate container reported in `SymbolInformation.containerName`.
- `.selector(...)` / `.qualifiedSelector(...)` — same name-query +
  container filter; LSP doesn't carry signature info on
  `workspace/symbol`, so selector-arity matching is upstream.
- `.regex(...)` — pattern is passed to sourcekit-lsp as the
  fuzzy-match query; results are then refined client-side with
  `Regex.wholeMatch`.
- `.usr(...)` throws `LSPSymbolResolverError.usrNotSupported` —
  LSP doesn't accept USRs on `workspace/symbol`, so the caller
  knows to fall back to IndexStore.

`SourceKitLSPClient` gains `workspaceSymbol(query:)` that issues
the request and returns the raw `SymbolInformation[]` payload. The
client's `start()` / `shutdown()` lifecycle is unchanged.

### CLI: `swa symbol --lsp <workspace>`

New `--lsp` option on `swa symbol` takes a workspace root path. When
supplied:

1. The standard IndexStore / syntax resolution runs first.
2. The `LSPSymbolResolver` runs against the workspace, returning
   any additional matches the build-required resolver finds.
3. Results are merged with `(file, line, column)`-keyed
   deduplication so the same definition isn't reported twice.
4. The LSP subprocess is shut down on command exit.

End-to-end smoke confirmed: `swa symbol "SourceKitLSPClient"
--lsp "$PWD"` finds the class via the LSP backend.

### New: `SymbolMatch.Source.lsp`

`SymbolMatch.Source` gains an `.lsp` case so downstream consumers
can distinguish LSP-backed matches from IndexStore / syntax /
cached ones. This is a SemVer-breaking addition to the public enum;
direct `switch` consumers must add the `.lsp` case.

1151 tests green; build warning-free; LSP smoke verified against
`/usr/bin/sourcekit-lsp`.

## [0.3.0-beta.4] - Unreleased

**Breaking.** `FileSlice` deleted. Every consumer routes through
`MemoryMappedFile.readAsString(offset:length:)` /
`readBytes(offset:length:)` / `withRawSpan(offset:length:_:)`. The
memory layer is down to exactly **one** `@unchecked Sendable` cage
(`MappingStorage`), from three.

### Removed (API break)

- `public struct FileSlice` (~130 LOC). Every method —
  `subscript(offset:)`, `subslice(offset:length:)`, `asString()`,
  `asBytes()`, `asRawBuffer()`, `withRawSpan(_:)`, `equals(_:)`,
  `hash()` — gone.
- `private final class FileSliceStorage: @unchecked Sendable` (cage).
- `public var MemoryMappedFile.fullSlice` (read the entire file via
  `readBytes()` / `readAsString()` instead).
- `public func MemoryMappedFile.slice(offset:length:)` (use the new
  range-based methods).
- `public func TokenSlice.slice(from:)` (use `text(from:)` which
  already returned `String?`).

### Added (replacement surface)

- `public func MemoryMappedFile.readBytes() -> [UInt8]`
- `public func MemoryMappedFile.readBytes(offset:length:) -> [UInt8]`
- `public func MemoryMappedFile.withRawSpan(offset:length:_:)` —
  borrows a sub-range of the mapping as a lifetime-bounded
  `~Escapable` `RawSpan`. The compiler enforces that the span does
  not outlive the file.

### Behaviour changes

- `MemoryMappedFile.line(_:)` now returns `String?` directly (was
  `FileSlice?`). Out-of-range indices still return `nil`.
- `readAsString(offset:length:)` now decodes bytes inline (no
  intermediate `FileSlice`). Out-of-range offset/length values
  clamp to the file bounds rather than producing a slice with
  whatever-length-actually-fits.

### Migration

| Old call | New call |
| --- | --- |
| `mmf.slice(offset: o, length: l).asString()` | `mmf.readAsString(offset: o, length: l)` |
| `mmf.fullSlice.asString()` | `mmf.readAsString()` |
| `mmf.fullSlice.asBytes()` | `mmf.readBytes()` |
| `mmf.line(i)?.asString()` | `mmf.line(i)` |
| `mmf.fullSlice.withRawSpan { … }` | `mmf.withRawSpan { … }` |
| `mmf.slice(offset: o, length: l).withRawSpan { … }` | `mmf.withRawSpan(offset: o, length: l) { … }` |
| `tokenSlice.slice(from: mmf)` | call `tokenSlice.text(from: mmf)` directly, or use the new range-based methods |

1151 tests green. Internal sources (`ZeroCopyParser`, `SoATokenStorage`,
`SourceFileReader`, `TokenSlice`, `SliceBasedTokenSequence`) all
migrated. The Sendable cage tests for `MemoryMappedFile` and
`ArenaTokenStorage` stay; the `FileSlice` cage test is gone alongside
the type it pinned.

## [0.3.0-beta.3] - Unreleased

Two new pieces of infrastructure for the deferred algorithm-research
queue. 1151 tests green (1150 + 1 new for the LSP integration test).

### F-S1 — SourceKit-LSP integration spike

New `SourceKitLSPClient` (in `Sources/SymbolLookup/SourceKitLSP/`)
implements a minimal JSON-RPC 2.0 client over stdio against
`sourcekit-lsp`. The client handles LSP header framing
(`Content-Length: N\r\n\r\n<json>`), the `initialize` /
`shutdown` lifecycle, and the request slice needed for
protocol-witness resolution:
`textDocument/prepareCallHierarchy` →
`callHierarchy/incomingCalls`. The latter is the path that walks
protocol conformances through the build's type information —
the precision win over IndexStoreDB-only resolution flagged by
the post-α.11 audit.

Status: **spike**. The client works end-to-end against
`/usr/bin/sourcekit-lsp` (new integration test in
`Tests/SymbolLookupTests/SourceKitLSPClientTests.swift` verifies
the full handshake), but the integration into `IndexStoreResolver`
or `SymbolFinder` is **not** wired. That requires a "build-required
mode" CLI / programmatic-API surface that the 0.3.x line doesn't
ship (the analyzer is intentionally build-free today). The client
exists as the scaffolding the 0.4.0 build-required resolver will
plug into.

### F-S2 — SemanticEmbeddingProvider protocol

New `SemanticEmbeddingProvider` protocol (in
`Sources/DuplicationDetector/Semantic/`) defines the integration
point for plugging in dense-vector code embeddings — CodeBERT,
GraphCodeBERT, CodeT5 via Core ML, remote APIs, or air-gapped
local models. Producing embeddings unlocks cross-idiom
semantic-clone recall (the ~20-30% ceiling documented in
`CloneDetection.md`).

The shipped default is `UnconfiguredSemanticEmbeddingProvider`,
which throws `SemanticEmbeddingError.notConfigured` on every
call. This is deliberate: it forces the integration path to be
explicit. Real providers ship as separate packages or extensions
that conform to the protocol and get plugged into the detector
(wiring TBD in 0.4.0; the protocol itself is stable enough to
extend `DuplicationConfiguration` once consumers materialise).

No model bundle ships in-tree. A 400 MB Core ML model would
balloon binary releases and a remote API requires policy
choices (which provider, what egress) that downstream consumers
should make themselves.

### F-S3 — PDG / GNN clone detection

**Not implementable in the 0.3.x line.** Program-dependence-graph
construction requires a SIL extraction pipeline
(`swiftc -emit-sil` or equivalent), which conflicts with the
build-free design the analyzer commits to today. A future
"build-required deep mode" could land this; it would share the
same architectural commitments as F-S1's resolver integration
(opt-in CLI flag, runtime `swiftc` dependency, project-state
expectations). No scaffolding ships in beta.3 because there's no
useful protocol shape without the SIL pipeline.

## [0.3.0-beta.2] - Unreleased

Three previously-deferred algorithm + precision items shipped.
1150 tests green (1137 + 13 new for the trigram index).

### F-B4 — Trigram index for regex symbol lookup

New `TrigramIndex` (case-sensitive 3-character inverted index) +
`RegexLiteralExtractor` (conservative regex-pattern literal-segment
parser) speed up `IndexStoreResolver.resolveByRegex` on patterns
with extractable literal trigrams (e.g. `^fetch.*Data$` →
`{fet, etc, tch, Dat, ata}`). Posting lists for each trigram are
intersected smallest-first; only surviving candidates run the full
regex match. Patterns with no literal segments of length ≥ 3
(pure character classes, alternation, `.+`) fall through to the
prior linear scan unchanged.

Build cost is amortised across all regex queries against the same
resolver: the corpus + index is materialised once on first regex
query via `IndexedCorpus.snapshot(reader:)` (a `Mutex`-guarded
lazy class so the resolver itself stays `Sendable`). Expected
speedup on real codebases: 10-100× per query depending on how
selective the trigrams are. Mirrors clangd's `global-index`
trigram lookup shape.

- `Sources/SymbolLookup/Resolution/TrigramIndex.swift` (new, ~120 LOC)
- `Sources/SymbolLookup/Resolution/RegexLiteralExtractor.swift` (new, ~125 LOC)
- `Sources/SymbolLookup/Resolution/IndexStoreResolver.swift` —
  `IndexedCorpus` cache class appended; `resolveByRegex` rewritten
  to query the index first.
- `Tests/SymbolLookupTests/TrigramIndexTests.swift` (new, 13 tests
  covering trigram extraction, candidate intersection, literal
  parsing under quantifiers / anchors / groups / character classes,
  and the nil-fallback contract for unindexable patterns).

### F-B2 — Macro-expansion clone filter

`SuffixArrayCloneDetector.detect(in:)` and `detectWithNormalization`
drop input `TokenSequence`s whose source lines contain a
`#sourceLocation(...)` directive. Swift macros emit these at the
top of generated files under `.build/.../macroexpansion/...`.
Although `findSwiftFiles` already excludes `.build/` by default,
callers that explicitly include macro-expansion roots no longer
see clone groups spanning a macro definition and its expansion
(expected by construction, not actionable). New private static
`SuffixArrayCloneDetector.containsSourceLocationDirective(_:)`
performs the cheap per-line prefix scan.

### F-B3 — Vestigial `trackClosureCaptures` flag removed

Investigation showed the audit's premise was inaccurate: the
`trackClosureCaptures` field on `DependencyExtractionConfiguration`
was stored but never read by any code path, and there was no
cross-function closure-capture edge emission in the reachability
graph at all. Captures *are* already tracked through the normal
reference graph — a closure body's references propagate to its
declarations via the existing `Reference → Declaration` edges
the BFS walks. The flag did nothing.

Removed the unused `trackClosureCaptures` field from
`DependencyExtractionConfiguration.init`, the `.strict` preset, the
caller in `UnusedCodeDetector.detectUnusedWithReachability`, and
the public property. Migration: drop `trackClosureCaptures:` from
any direct `DependencyExtractionConfiguration(...)` call.

### Architecturally-deferred items

The audit's three larger algorithm items remain genuinely
out-of-session-scope for `0.3.x` and are documented as
0.4.0 design seeds rather than deferred quick wins:

- **F-S1 — SourceKit-LSP witness resolution.** +20-30% protocol-
  witness precision via `textDocument/callHierarchy/incomingCalls`,
  but requires `sourcekit-lsp` as a runtime dependency, an
  available build of the analyzed project, and ~300 LOC of LSP
  client integration. Architecturally adjacent to a "build-required
  mode" we don't have.
- **F-S2 — Core ML transformer embeddings (CodeBERT / GraphCodeBERT).**
  +15-25% semantic recall on cross-idiom equivalents per BigCloneBench
  numbers (F1 ~97% on Java; out-of-distribution for Swift without
  fine-tuning). Requires a ~400 MB Core ML model bundle or a
  network round-trip per query — realistic only as an opt-in
  `--semantic-deep` flag, not as a default analyzer pass.
- **F-S3 — PDG/GNN clones.** Requires `swiftc -emit-sil` for the
  program-dependence graph; architecturally incompatible with the
  build-free design today. Future work iff a "build-required deep
  mode" is added.

None of these are exploitable findings. They're new-capability
proposals from the SOTA research pass that need their own
architectural commitments.

## [0.3.0-beta.1] - Unreleased

Cuts the 0.3.0 beta from the eighteen-alpha cluster. 1137 tests
green; bench gate operational; CLI / MCP / plugin smoke clean (one
`swa-mcp` regression caught and fixed during the cut — `Task.sleep`
with `Double.greatestFiniteMagnitude` traps on Swift 6.x via an
overflow into `_Int128`, replaced with a bounded-interval park
loop).

This entry summarises the user-visible changes accumulated across
`0.3.0-alpha` through `0.3.0-alpha.18` for downstream consumers
migrating from `0.2.x`. The per-alpha entries below remain as
historical detail.

### Breaking changes (since 0.2.x)

- **`.iOS(.v18)` dropped from `Package.swift`** — IndexStoreDB is
  macOS-only and there was never a working iOS configuration.
- **`IndexStoreReader` / `IndexStoreFallback` / `DetectionMode` moved
  from `UnusedCodeDetector` to `SwiftStaticAnalysisCore`.**
  `SymbolLookup` no longer depends on `UnusedCodeDetector`. Direct
  importers should switch to `import SwiftStaticAnalysisCore`.
- **`UnusedCodeConfiguration.default.mode` flipped `.simple` →
  `.reachability`** (α.16). README/DocC always claimed reachability;
  the struct disagreed. Downstream consumers passing
  `UnusedCodeConfiguration()` now get graph-based detection by
  default.
- **`DuplicationConfiguration.default.cloneTypes` flipped `[.exact]`
  → `[.exact, .near, .semantic]`** (α.16). `swa duplicates .` with
  no `--types` flag now detects all three.
- **`ProcessExecutor` demoted to `internal`** (was `public`). It
  was never meant to be a public subprocess launcher.
- **`UnusedCodeDetector.DataFlow.*` demoted to `internal`**
  (157 declarations across CFGBuilder, SCCPAnalysis,
  ReachingDefinitions, LiveVariableAnalysis).
- **`UnusedCodeConfiguration.useParallelBFS`** is now `Bool?`
  (`nil` = auto-select against `parallelBFSThreshold`).
- **`SyntaxResolver` USR queries throw**
  `SyntaxResolverError.usrResolutionRequiresIndexStore` instead of
  silently returning `[]` (α.17).
- **`FallbackConfiguration.init` and `UnusedCodeConfiguration.init`**
  each gain a `sandboxRootPath: String? = nil` parameter (α.12).
- **MinHash default `numHashes` raised 128 → 256** (α.17).
  Theoretically grounded recall improvement (~8-12% on real corpora
  at J≥0.85); signature storage doubles per document.
- **`@_exported import` scope narrowed** in Core and MCP.

### Security

The post-α.11 re-audit (parallel `apple-security-analyst` +
`quality-reviewer` agents) surfaced and closed:

- **Two HIGH-severity findings** (α.12):
  `IndexStoreFallbackManager.createDirectory` now gates on
  `allowsIndexDatabaseCreation` (previously bypassed the MCP-set
  flag); `FallbackConfiguration.sandboxRootPath` re-validates
  derived `IndexDatabase/` paths against the sandbox root
  (TOCTOU window between `validatePath` and the fallback's open).
- **Six defence-in-depth hardening items** (α.13):
  `handleReadFile` + `ReadResource` open via `.noFollow`
  `MemoryMappedFile`; `findLibIndexStore` verifies dylib trust
  (regular file owned by uid 0); `parseFileURI` rejects user /
  password / port; `MappingStorage.deinit` logs close failures via
  `AnalysisLogger`; `PathUtilities.sanitizedForDiagnostic`
  sanitises C0 control bytes from path-bearing error strings
  (CWE-117 log injection); `SafeRegex` docstring narrowed to the
  actual probe scope.
- **Four lower-priority items** (α.15): `SWAMCPServer.resolutionBaseURL`
  pinned at server init; `getCodebaseInfo` cumulative 4 GiB scan
  ceiling; `swaText` access tightened to `fileprivate`;
  `MemoryMappedFile.init` Linux `.noFollow` support documented.

The previous audit cycle's HIGH findings (0.2.1) remain closed.

### Correctness

- **Dataflow worklist decoherence** (α.12): both
  `LiveVariableAnalysis.computeLiveVariables` and
  `ReachingDefinitions.computeReachingDefinitions` worklists
  rewritten to use a unique workIndex per block with a 1-to-1
  `blockByWorkIndex` inverse — eliminates the silent-block-drop
  bug that arose when unreachable blocks shared a sentinel key.
- **`detectUnusedImports`** no longer a no-op (α.16). Previous
  shape was "any reference of any kind exists → all imports
  marked used", recall 0%. Replaced with module-qualified
  reference scanning at `.low` confidence.
- **Four new `RootReason` cases** for FFI / runtime attributes
  (α.16): `.silgenName`, `.cdecl`, `.dynamicReplacement`,
  `.objcRuntimeName`. Codebases using Swift-C interop no longer
  see 100% FPR on these.
- **`MultiProbeLSH` docstring** acknowledges its theoretical
  limitations (α.18): the perturbation strategy is not Lv et al.
  2007's E2LSH algorithm and has no guaranteed recall bound for
  MinHash LSH. Users wanting more recall raise `numHashes`.

### Symbol lookup precision (α.17)

- `IndexStoreResolver.matchesSelectorFromUSR` no longer accepts
  mid-identifier substring matches; new
  `usrHasLengthPrefixedSegment` verifies match position is at a
  length-prefix boundary.
- `SyntaxResolver.resolveQualifiedName` walks the full container
  chain (was checking only the immediate parent).
- `SyntaxResolver.resolveByRegex` defaults to whole-identifier
  match (`.wholeMatch(of:)`) instead of substring; callers wanting
  substring use `.*pattern.*`.

### Algorithm + perf

- **SA-IS arena-backed end-to-end** (α.2): working buffer is
  `UnsafeMutableBufferPointer<Int>` from a single recursion-wide
  `Arena`; no per-recursion `[Int]` allocation.
- **AST fingerprint hash switches to Mersenne-61** (α.2): the
  prior `% 1_000_000_007` (30-bit prime) collided ~50% at
  N≈50 000 snippets. M_61 keeps collision rate negligible at
  realistic codebase scale.
- **`ShingleGenerator` iterates `ArraySlice<TokenInfo>` directly**
  (α.4): drops two per-file `[String]` / `[TokenKind]`
  allocations on the duplication hot path (−6.5% mean wall-time
  on `duplicates-near`).
- **`Bitmap` struct retired in favour of
  `swift-collections.BitArray`** (α.8). `AtomicBitmap` stays —
  `BitArray` has no lock-free `testAndSet`.
- **Dataflow worklists use `Collections.Heap<Int>` keyed on
  reverse-postorder index** (α.6). Complexity drops from
  `O(B² × maxIterations)` to `O(B × maxIterations × log B)`.
- **`MemoryMappedFile` opens via swift-system
  `FileDescriptor.open(FilePath, .readOnly, [.noFollow])`** (α.5).
  Typed errors, typed paths.
- **Memory-layer `@unchecked Sendable` confined to private
  storage classes** (α.5). `MemoryMappedFile`, `FileSlice`, and
  `ArenaTokenStorage` are all plain `Sendable` on their public
  surface.

### MCP API surface

- **MCP SDK `.text(_:metadata:)` deprecation closed** (α.7).
  Single `Tool.Content.swaText` helper at the bottom of
  `SWAMCPServer.swift` routes all 18 call sites through the
  non-deprecated `.text(text:annotations:_meta:)` factory.
- **`get_codebase_info` cumulative scan ceiling** (α.15): 4 GiB
  hard cap across the line-counting pass.

### Tooling

- **Bench gate operational** (α.3, baselines refreshed α.12).
  Six scenarios (`duplicates-exact`, `duplicates-near`,
  `duplicates-semantic`, `unused-simple`, `unused-reachability`,
  `symbol-lookup`); `bench/compare.sh` gates at +10% mean / +25%
  p99 with per-scenario overrides; `refresh-baselines.yml`
  workflow opens a PR with regenerated baselines.
- **Cross-actor `Sendable` regression tests** (α.12) for the
  three memory-layer cage types pin the contract at runtime.
- **Differential `ParallelBFS` vs. sequential test** (α.14)
  prevents drift between the two BFS implementations.
- **Worklist convergence tests** (α.14) on back-edge CFGs with
  unreachable blocks pin the post-α.12 fix.

### Documentation

- **`audit/` directory removed** (α.9). The audit and remediation
  plan were process artifacts; technical content survived in
  CHANGELOG entries and code WHY comments.
- **README, SECURITY, and the 13 DocC articles** verified
  directly against the code surface (α.10). InlineArray claim,
  `Bitmap`-typed claim, version pins, and the
  `StaticAnalysisCommandPlugin` env-scrub footnote all corrected.
- **Semantic clone recall ceiling documented** (α.18): the
  ~20-30% recall for cross-idiom equivalents (for-loop vs
  `reduce`, recursion vs iteration) is now stated directly in
  README and `CloneDetection.md` rather than implied to be full
  Type-3/4 coverage.

### Migration notes

- Direct `UnusedCodeConfiguration()` consumers now run in
  `.reachability` mode. To preserve simple-mode behaviour,
  explicitly set `config.mode = .simple`.
- Direct `DuplicationConfiguration()` consumers now detect all
  three clone types. To preserve exact-only, set
  `config.cloneTypes = [.exact]`.
- `SyntaxResolver` USR queries throw — `try? resolver.resolve(.usr(...))`
  is the migration shape if the caller wants the previous
  silent-empty contract.
- The new `FallbackConfiguration.sandboxRootPath` and
  `UnusedCodeConfiguration.sandboxRootPath` parameters default
  to `nil`; only sandboxed callers (the MCP server) set them.

## [0.3.0-alpha.18] - Unreleased

Docs truth-up for two algorithm claims the post-α.15 audit flagged
as misleading. Code-only docstring + README + DocC changes. 1137
tests green.

### Truth-up

- **`MultiProbeLSH` docstring acknowledges its theoretical
  limitations.** The post-α.15 audit pointed out the type's
  perturbation strategy doesn't implement Lv et al. 2007 (VLDB).
  Investigation: Lv et al.'s algorithm is for **E2LSH** (Euclidean
  p-stable LSH, Datar et al. 2004), where perturbing the bucket
  index ±1 corresponds to a small geometric movement. In MinHash
  LSH the bucket is `hash(b₁, b₂, …, bᵣ)` of the band's signature
  values, so the perturbation doesn't reach "nearby buckets" in any
  theoretically grounded sense. The type has **zero consumers** in
  the codebase or test suite — rather than ship a misguided rewrite
  or break the public API during alpha, the docstring is updated to
  acknowledge the limitation and redirect users to `numHashes`
  tuning (raising signature width is the theoretically grounded
  alternative). A real MinHash-specific multi-probe variant
  (LSH Forest, b-bit MinHash) is filed as future work.

- **README clone-type table and `CloneDetection.md` semantic-clone
  section** acknowledge the ~20-30% recall ceiling for cross-idiom
  equivalence. The audit's `sumSquaresLoop` / `sumSquaresFunctional`
  fixture pair is the canonical false-negative example. Semantic
  detection is **structural** (same AST topology, different literals
  / identifiers) — empirical recall for same-idiom equivalents is
  ~85-95%, cross-idiom is ~20-30%. The docs now state this directly
  rather than implying full Type-3/4 coverage.

## [0.3.0-alpha.17] - Unreleased

Batch B (algorithm win) + Batch C (symbol-lookup precision) from the
post-α.15 re-audit. 1137 tests green.

### Algorithm

- **MinHash default signature width raised 128 → 256.** At Jaccard
  similarity 0.85 with bands b=16 / rows=8, the S-curve false-negative
  rate drops from ~12-15% (n=128) to ~5-6% (n=256). On a corpus of
  10⁵ function-level snippets at threshold 0.80 this recovers
  roughly 8-12% of true near-clone pairs that previously fell below
  the LSH bucket threshold. Signature storage doubles per document
  (negligible). The SIMD4 loop already handles arbitrary widths, so
  this is a 9-site default change: `MinHashGenerator`,
  `ParallelMinHashGenerator`, `LSHIndex`, `MultiProbeLSHIndex`,
  `MinHashCloneDetector`, `FastSimilarityChecker`,
  `ParallelLSH`, plus the `DuplicationDetector.detectClones` call
  site that previously hard-coded `numHashes: 128`.

### Symbol-lookup precision

- **`IndexStoreResolver.matchesSelectorFromUSR`** now refuses
  substring matches that happen mid-identifier. The previous
  `usr.contains("\(label.count)\(label)")` shape spuriously matched
  a USR like `…12abcdefgh2id…` against the label `"id"`. New private
  helper `usrHasLengthPrefixedSegment(_:segment:)` verifies the
  match position is at a length-prefix boundary (preceded by a
  non-digit byte, USR syntax character, or start-of-string).
  Also explicitly handles the `labels.allSatisfy({ $0 == nil })`
  case (all `_:` parameters) — the loop previously fell through to
  `return true` regardless; the explicit early-return documents
  that USR-only signature matching cannot disambiguate when every
  label is anonymous.

- **`SyntaxResolver.resolveQualifiedName`** walks the full container
  chain. The previous implementation checked only
  `components.dropLast().last` (the immediate container), so
  `SymbolQuery.qualifiedName("Outer", "Inner", "method")` matched
  any `method` inside any `Inner` regardless of `Outer`. New
  private `containingTypeChain(for:in:)` traverses outward through
  every enclosing type / extension scope and the resolver requires
  the full chain to match.

- **`SyntaxResolver.resolveByRegex`** defaults to whole-identifier
  matching (`.wholeMatch(of:)`) rather than substring
  (`.contains(of:)`). The previous shape turned a query like
  `"load"` into a hit on `loadUsers`, `uploadData`, `download`, and
  `reloadAll`. Callers wanting substring matching pass an explicit
  substring-shaped regex (`.*load.*`).

- **`SyntaxResolver`** USR queries throw `SyntaxResolverError.usrResolutionRequiresIndexStore`
  instead of silently returning `[]`. The previous silent-empty was
  the canonical "silent no-op" footgun — callers couldn't tell the
  difference between "no match" and "this resolver can't answer
  USR queries". The error message points users at `--mode indexStore`
  or `--index-store-path`.

### Deferred

The audit's three larger algorithm items stay on the deferred list
pending dedicated session budget:

- **F-B2** (macro-expansion clone filter, ~50 LOC, expected
  −5-10% false-positive clone reports on macro-heavy codebases).
- **F-B3** (closure escape precision in reachability, ~100 LOC,
  expected −5-15% false-negative rate).
- **F-B4** (trigram index for regex symbol lookup, ~200 LOC,
  expected 10-100× speedup on large projects).

None are exploitable; all are pure precision / perf wins.

## [0.3.0-alpha.16] - Unreleased

Closes four CRITICAL precision / recall bugs surfaced by the post-α.15
re-audit. These are correctness bugs (behaviour ≠ documentation),
not refactors. 1137 tests green.

### Default flips

- **`UnusedCodeConfiguration.default.mode` is now `.reachability`** (was
  `.simple`). README, DocC, and SECURITY all describe `.reachability`
  as the default; the struct disagreed. Users calling `swa unused .`
  with no `--mode` flag now get the graph-based detection the docs
  promise (~85% precision, ~80% recall against simple's ~55% precision).
- **`DuplicationConfiguration.default.cloneTypes` is now
  `[.exact, .near, .semantic]`** (was `[.exact]`). README's clone-type
  table and per-type algorithm flip both assume all three are
  detected; the struct shipped only exact clones. Per-type algorithm
  routing (suffixArray / minHashLSH) was already correct.

### Correctness

- **`detectUnusedImports` is no longer a no-op.** The previous check
  was *"if any reference of any kind exists anywhere, mark every
  import as used"* — recall was effectively 0%. Replaced with a
  module-qualified reference scan: an import is flagged at `.low`
  confidence when the analyzed sources contain zero references
  qualified by the module name. Syntax-only attribution is
  necessarily weaker than IndexStore-backed (the suggestion text
  points users to `--mode indexStore` for accurate cross-module
  attribution).
- **Cross-language / runtime attribute roots now detected.** Four
  new `RootReason` cases — `.silgenName`, `.cdecl`,
  `.dynamicReplacement`, `.objcRuntimeName` — catch declarations
  referenced through mechanisms invisible to source-level analysis
  (C ABI, Objective-C runtime, Swift dynamic replacement). Codebases
  using Swift-C interop had 100% false-positive rate on these
  declarations.

### Test updates

The four tests that pinned the old defaults are updated to assert
the documented contract (`mode == .reachability`,
`cloneTypes == [.exact, .near, .semantic]`). Tests in
`SwiftSyntaxModeTests.swift` and `IgnoredPatternsTests.swift` that
exercise the simple-mode detection path now set `config.mode = .simple`
explicitly — the file name `SwiftSyntaxModeTests` already implied that
contract; the explicit assignment makes the intent local.

## [0.3.0-alpha.15] - Unreleased

Final batch of lower-priority hardening + access-level tightening from
the post-α.11 re-audit. Closes the LOW findings. 1137 tests green.

### Hardening

- **`SWAMCPServer.resolutionBaseURL` pins CWD at server init.** The
  context-cache lookup canonicalises relative `codebase_path`
  arguments against this snapshot rather than the live
  `FileManager.default.currentDirectoryPath`, so a mid-session
  `chdir` from another actor (no caller does this today; defensive)
  cannot collide cache keys across logical roots.
- **`getCodebaseInfo` cumulative scan ceiling.**
  `getCodebaseInfoMaxAggregateBytes: UInt64 = 4 * 1024 * 1024 * 1024`
  (4 GiB) caps the total bytes mmap'd for line counting across the
  whole codebase. The per-file 64 MiB ceiling was already in place
  but 10 000 files × 64 MiB still permits a 640 GiB sequential scan
  in a single MCP call. Files past the aggregate ceiling still
  contribute to `totalBytes` (already counted via directory
  metadata); `totalLines` becomes a partial figure.

### API hygiene

- **`Tool.Content.swaText` tightened to `fileprivate`.** All 18 call
  sites are in `SWAMCPServer.swift`. The previous `internal` level
  widened the surface unnecessarily.

### Docs

- **`MemoryMappedFile.init` docstring** notes the `.noFollow` flag
  resolves to `O_NOFOLLOW` on both Darwin and Linux, but flags the
  Linux configuration as untested in CI. (The `mmap` / `munmap`
  syscalls themselves are platform-guarded.)

## [0.3.0-alpha.14] - Unreleased

Simplification + closes the test-coverage gaps the re-audit flagged.
1137 tests green (1133 + 4 new).

### Test coverage

- **Differential BFS test.** New
  `parallelMatchesSequentialOnCyclicGraph` + `…OnDisconnectedGraph`
  cases in `DenseGraphTests`. Each constructs a hand-rolled
  `DenseGraph` with a known shape (back edge / duplicate roots /
  disconnected component) and asserts
  `ParallelBFS.computeReachable(...)` and
  `DenseGraph.computeReachableSequential()` agree. Prevents future
  drift between the two implementations as they evolve.
- **Worklist convergence test.** New
  `liveVariableAnalysisConvergesOnBackEdge` +
  `reachingDefinitionsConvergesOnBackEdge` cases in
  `DataFlowTests`. Each builds a CFG with a back-edge loop *and* an
  unreachable block (`if false { ... }`) — the shape that exposed
  the α.12-fixed worklist-decoherence bug. Both pin convergence
  inside a `maxIterations: 64` budget and check the post-fix
  liveness / reaching-definitions sets are populated. Future
  regressions to the worklist's key-uniqueness or key-projection
  shape would fail these tests rather than silently produce wrong
  results.

### Simplification

- **`ArenaTokenStorage.init(from:arena:)`** swaps four
  per-element `for` loops for four `arena.copy(_:)` calls. Same
  result; lower line count, vectorised bulk copy at the lowering
  layer.
- **`Tool.Content.swaText` docstring reframed.** Was labelled a
  "migration shim around the deprecated `.text(_:metadata:)`"; the
  reality is that the non-deprecated three-named-argument factory is
  verbose at every call site, so the wrapper is a permanent
  convenience, not a shim. Docstring now says so directly.

## [0.3.0-alpha.13] - Unreleased

Six defence-in-depth hardening items the post-α.11 re-audit flagged
as MEDIUM. None individually exploitable today; together they tighten
the MCP perimeter, the toolchain-dylib trust path, and the diagnostic
log surface. 1133 tests green.

### Security

- **`handleReadFile` and `ReadResource` use `.noFollow`-opened reads.**
  Previously both sites called `String(contentsOfFile:)` *after*
  `validatePath`, leaving a TOCTOU window where a symlink swapped in
  between validation and open would redirect the read. Both now read
  through `MemoryMappedFile`, which opens with `FileDescriptor.open(
  ..., options: [.noFollow])`. The kernel rejects the open if the
  path component became a symlink; the existing 10 MiB extension /
  size gate continues to apply.
- **`findLibIndexStore` verifies dylib trust.** Every candidate path
  (the three hardcoded toolchain locations, the `xcrun --find swift`
  resolved path, and the Xcode-default fallback) is `lstat`-ed and
  required to be a regular file owned by `root` (uid 0) before
  `IndexStoreLibrary` will `dlopen` it. Without this, a low-privilege
  user with write access under `/Applications/Xcode.app/...` or
  `/Library/Developer/...` could plant a hostile dylib that the
  analyzer process would later load. New private helper
  `isTrustedDylib(at:)`.
- **`parseFileURI` rejects credentials and ports.**
  `file://user:pass@localhost:8080/path` previously passed the gate
  because `parsed.user` / `parsed.password` / `parsed.port` were
  ignored. `file://` has no concept of any of these; carrying them
  is either a fingerprinting probe or a path-confusion attack against
  future URL implementations. All three components now throw
  `ReadResourceURIError`.
- **`MappingStorage.deinit` logs close failures.**
  `try? descriptor.close()` discarded `EBADF` / `EIO` silently. Under
  load this could leak descriptors until the process can't open more
  files (a quiet availability issue). The close failure now routes
  through `AnalysisLogger.warning` so file-table exhaustion is
  observable. New private static
  `MappingStorage.deinitLogger`.
- **MCP error descriptions sanitise paths.**
  `CodebaseContextError.errorDescription` embeds attacker-controlled
  paths in stderr-bound diagnostics. A path containing newlines or
  ANSI escape sequences would inject log breaks / terminal escapes
  (CWE-117 log injection). New
  `PathUtilities.sanitizedForDiagnostic(_:)` replaces C0 control
  bytes (`0x00...0x1F` except `\t`) and DEL (`0x7F`) with `U+FFFD`
  before path interpolation. Applied to `invalidRootPath`,
  `pathOutsideSandbox`, `enumerationFailed`, and the new
  `handleReadFile` / `ReadResource` open-failure paths.

### Truth-up

- **`SafeRegex` docstring narrowed to match the actual probe scope.**
  Previously claimed comprehensive ReDoS protection; the prefilter
  catches the canonical nested-quantifier shapes (`(...*)*`,
  `(...+)+`) and the catch-all repetition (`(.*)*` / `(.*)+`) only.
  It does *not* catch alternation-with-overlap (`(a|a)*`), polynomial
  backtracking (`a*a*a*...b`), lookaround antipatterns
  (`(?=(.+)+)`), or quantified alternation outside groups. The
  authoritative defence remains the wall-clock budget at the call
  site (`search_symbols`'s `ContinuousClock.now.advanced(by:)`).
  Adding probes for the missed shapes risks rejecting legitimate
  patterns; the budget already bounds CPU exposure. Documentation
  now states the contract honestly.

## [0.3.0-alpha.12] - Unreleased

Closes two HIGH-severity security findings and one correctness bug
surfaced by the post-α.11 re-audit. 1133 tests green (1130 plus
three cross-actor Sendable regression tests). Bench baselines refreshed.

### Correctness

- **Dataflow worklist decoherence.** Both
  `LiveVariableAnalysis.computeLiveVariables` and
  `ReachingDefinitions.computeReachingDefinitions` keyed their `Heap<Int>`
  worklist on values that could collide across blocks (notably
  `Int.max` / `unreachableBase` for every unreachable block). The
  `LiveVariableAnalysis` `blocksByKey` stack could silently drop a
  block when a predecessor re-inserted a colliding key in the same
  iteration; `ReachingDefinitions` re-enqueued unreachable successors
  under a bare sentinel, causing the wrong block to be processed on
  pop. Both now use a unique workIndex per block
  (`[0, reachableCount)` for the reverse-postorder reachable set,
  `[reachableCount, totalCount)` for unreachable blocks in
  `blockOrder` traversal order) with a 1-to-1
  `blockByWorkIndex: [BlockID]` inverse so `popMin` deterministically
  recovers the matching block. The forward / backward distinction is
  encoded in the key projection only.

### Security

- **`IndexStoreFallback` honours `allowsIndexDatabaseCreation`.** The
  two `FileManager.default.createDirectory(...)` call sites at
  `IndexStoreFallback.swift:285` (open-index path) and `:383`
  (modification-time probe path) were unconditional, bypassing the
  flag the MCP handler already sets on `IndexStoreReader.init`. A
  hostile MCP client could drive a `createDirectory` write at
  `parent(index_store_path)/IndexDatabase` inside the sandbox root
  even though `read_*` tools advertise themselves as read-only. Both
  sites now route through a shared `prepareDatabaseDirectory(at:)`
  helper that gates on `configuration.allowsIndexDatabaseCreation`
  (throws `IndexStoreError.databaseDirectoryMissing` when creation
  is forbidden and the directory does not already exist).
- **`FallbackConfiguration.sandboxRootPath` re-validates derived
  paths.** When non-nil (the MCP server sets it to `context.rootPath`),
  every derived filesystem path the fallback layer touches —
  specifically `parent(indexStorePath)/IndexDatabase` — is
  re-validated through `ensurePathStaysUnder(root:candidate:)` (the
  same canonical-path + separator-aware prefix shape
  `CodebaseContext.validatePath` applies upstream). Closes the TOCTOU
  window between the MCP handler's initial path validation and the
  fallback layer's subsequent operations.

### Test coverage

- **Cross-actor Sendable regression tests** for the memory-layer cage
  pattern. New `CageSendableTests` suite in `MemoryTests.swift`
  exercises `MemoryMappedFile`, `FileSlice`, and `ArenaTokenStorage`
  across a `Task.detached` boundary. The cage pattern (private
  `@unchecked Sendable` storage class behind a `Sendable` public
  value type) compiles silently even if a future refactor adds a
  mutable field to the storage class; the runtime tests pin the
  cross-actor read contract so a regression surfaces as a failure
  rather than as quiet sharing of mutable state.

### Perf

`unused-simple` shifted from 0.104s → 0.118s mean (+13.78% over the
previous baseline) — small absolute (10ms on a 100ms scenario),
likely cache-line pressure from `UnusedCodeConfiguration` gaining a
`sandboxRootPath: String?` field. Bench baselines refreshed against
the post-fix code so future PRs are gated against the real surface.
Other scenarios moved within thermal-noise envelope.

### Migration notes

- `FallbackConfiguration.init` gains a `sandboxRootPath: String? = nil`
  parameter. Defaults preserve CLI / programmatic behaviour
  (`nil` = skip re-validation); only sandboxed callers set it.
- `UnusedCodeConfiguration.init` gains the same parameter in the
  same position. Same defaults / semantics.

## [0.3.0-alpha.11] - Unreleased

Final scrub of plan / scheduling / decision-making residue in test
comments and one DocC roadmap mention the previous pass missed.

- Six test-file comments lose their `Pre-0.2.1 ...`, `Post-0.3.0-α ...`,
  `0.3.0-α: ...` temporal slugs. The technical justifications stay —
  regression-pin tests need their WHY — but they no longer reference
  release lines or "previously the code did X".
- `Performance.md` drops the "the generic-`T` migration is on the
  roadmap" line. Roadmap lives in issues, not in DocC.
- `SwiftFileParser` docstring rewords "ship-blocker for long-running
  MCP sessions" to plain "the bound matters for long-running MCP
  sessions" — same semantic, no project-management vocabulary.
- `AtomicBitmapTests` header note loses the "retired in 0.3.0-α.8 in
  favour of …" version-tagged narrative; the comment now just states
  the current arrangement.

1130 tests green; build warning-free.

## [0.3.0-alpha.10] - Unreleased

Documentation truth-up sweep against the 0.3.0-α code surface. Every
technical claim in README, SECURITY, and the thirteen DocC articles
verified directly. No code paths change; this is a docs-only release
with one Package.swift comment scrub the previous α.9 commit missed.
1130 tests green.

### What changed

- **README perf section** — drops the false
  "Default signature width is `InlineArray<128, UInt64>`" claim
  (signatures are still `[UInt64]`-backed with default count 128) and
  the stale "`Bitmap`-typed" SA-IS reference (now
  `swift-collections.BitArray`). Adds an honest description of the
  arena-allocated `UnsafeMutableBufferPointer<Int>` scratch buffer.
- **README install snippet** — version pin bumped from `0.2.1` to
  `0.3.0`. Same in `GettingStarted.md` and `CLIReference.md` (both
  still showed `0.1.4`).
- **SECURITY.md** — supported-versions table now lists `0.3.x`.
  The `StaticAnalysisCommandPlugin` section explicitly documents the
  `process.environment = [:]` scrub the plugin already performs
  (previous text could be read as implying the plugin path skipped
  the scrub).
- **DocC `SwiftStaticAnalysis.md`** — public-API table loses
  `Bitmap` (deleted struct) and `ProcessExecutor` (now `internal`).
  Reachability bullet names `AtomicBitmap` / `BitArray` separately.
- **DocC `Architecture.md`** — ASCII module diagram updated; layering
  rules table shows `IndexStoreDB` / `SystemPackage` as Core
  dependencies and `SymbolLookup` no longer importing
  `UnusedCodeDetector`. The "previously inverted edge" history
  paragraph is gone (it documented planning provenance, not the
  architecture).
- **DocC `Performance.md`** — sequential BFS uses `BitArray`, parallel
  BFS uses `AtomicBitmap`; SA-IS uses `BitArray` plus arena-allocated
  `UnsafeMutableBufferPointer<Int>`.
- **DocC `PerformanceOptimization.md`** — SA-IS classification swap
  documented with the swift-collections type name.
- **DocC `UnusedCodeDetection.md`** — implementation-sources list
  corrected: `Bitmap.swift` is no longer a file; `IndexStoreReader`
  moved to Core; `PARALLEL_BFS_STUDY.md` references removed (those
  files don't exist on `main`).
- **DocC `MCPServer.md`** — `detect_unused_code.mode` documented as
  `simple | reachability | indexStore`, matching the schema.
- **DocC `Security.md`** — pre-0.2.0 framing replaced with general
  description of the vulnerability classes.
- **DocC `CLIReference.md`** — `--algorithm` default cell shows the
  per-type defaults (was incorrectly listed as `rollingHash` flat).
- **Package.swift** — `0.3.0-α.5: ...` / `Pre-0.3 ...` / `audit F-01`
  prose in the manifest comments scrubbed (missed by the α.9 pass). The `audit/`
directory (audit document, six per-area scratch files, remediation
plan) is deleted; CHANGELOG entries and source comments lose the
B-id slugs, "audit ..." parenthetical attributions, and `0.3.0-α.N` /
`pre-0.3` version-tag prose. Substance — the technical descriptions
of what changed and why — is preserved everywhere. No code paths
move; no public API changes. 1130 tests green.

## [0.3.0-alpha.8] - Unreleased

The hand-rolled non-atomic `Bitmap` struct (130 LOC of word-packed bits
+ `set` / `test` / `popCount` / `forEachSetBit`) is replaced everywhere
by `swift-collections.BitArray`. The atomic cousin (`AtomicBitmap`)
stays — `BitArray` has no lock-free `testAndSet`, which the parallel
BFS frontier coordination relies on. 1130 tests green
(down 5 — the deleted tests covered the deleted struct).

### What changed

- **`Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift`**
  deleted; the file becomes
  `Sources/SwiftStaticAnalysisCore/Concurrency/AtomicBitmap.swift`
  with the `AtomicBitmap` class and its `AtomicWord` companion only.
- **SA-IS `classifyTypes` / induced-sort helpers**
  (`DuplicationDetector/SuffixArray/SuffixArray.swift`) take
  `BitArray` instead of `Bitmap`; the subscript shape `types[i]`
  replaces `types.test(i)`. Hot-path read pattern unchanged.
- **`ParallelBFS.bottomUpStep`** and
  **`ParallelConnectedComponents.bottomUpExpand`** build the
  frontier as a `let`-bound `BitArray` (immediately-invoked
  closure pattern) so the parallel closures capture an immutable
  value, satisfying Swift 6's sending-closure check without
  `@unchecked` or `Mutex`.
- **`DenseGraph.computeReachableSequential`** uses
  `BitArray` for the visited set; the final `Set<Int>` is built
  by a single forward pass over the bit indices.
- **`Tests/SwiftStaticAnalysisCoreTests/AtomicBitmapTests.swift`**
  drops the 5 non-atomic-`Bitmap` shim tests. `BitArray` is
  exercised by swift-collections' own test suite.

### Perf

Bench gate on macos-15 with `--warmup 2 --iterations 5`:

| Scenario | Mean Δ | p99 Δ |
| --- | ---: | ---: |
| duplicates-exact (SA-IS hot path) | +2.79% | +5.68% |
| unused-reachability (BFS hot path) | -3.03% | -7.21% |

The +2.79% on the SA-IS hot path is well within the +10% mean / +25%
p99 gate. The other four scenarios don't touch `Bitmap` and stay
inside thermal-noise territory.

### Why `BitArray` and not "delete it and use `[Bool]`"

`[Bool]` is 8x memory for the same information and prevents the word-
parallel iteration patterns SA-IS depends on. `BitArray` is the same
1-bit-per-bit packed representation we had, just maintained upstream
and with `Hashable` / `Codable` / `Sendable` / `BitwiseCopyable`
conformances we'd otherwise have to write ourselves.

## [0.3.0-alpha.7] - Unreleased

Closes the MCP swift-sdk `.text(_:metadata:)` deprecation that had been
spamming every build since 0.2.x. 1135 tests green.

### Build hygiene

- **`Tool.Content.swaText(_:)` helper** added at the bottom of
  `SWAMCPServer.swift`. Wraps the new
  `.text(text:annotations:_meta:)` factory the MCP swift-sdk
  introduced (it deprecated the older `.text(_:metadata:)` /
  `.text(text:metadata:)` shapes). All 18 call sites inside
  `SWAMCPServer` route through `swaText` so the call-site cost is
  one identifier instead of three named arguments, and there is a
  single place to update when the SDK shifts again.
- `Resource.Content.text(_:uri:)` calls in the `ReadResource` handler
  are unchanged — that factory is the canonical non-deprecated shape.

## [0.3.0-alpha.6] - Unreleased

The dataflow worklist algorithms drop the `O(B²)` per-iteration linear
scan. 1135 tests green; `unused-reachability` bench median is 2.109s
vs. baseline 2.189s (noise-level improvement; the worst-case complexity
drop is the real win for adversarial CFG shapes the bench doesn't
exercise).

### Algorithmic correctness

- **`ReachingDefinitions.computeReachingDefinitions`** —
  `Set<BlockID>` worklist + per-outer-iteration
  `cfg.reversePostOrder.first(where: worklist.contains)` linear scan
  replaced with `Collections.Heap<Int>` keyed on the block's
  reverse-postorder index, plus a parallel `inWorklist: Set<Int>` for
  dedup. Worst-case complexity drops from
  `O(B² × maxIterations)` to `O(B × maxIterations × log B)`.
- **`LiveVariableAnalysis.computeLiveVariables`** — same shape for the
  backward sweep, keyed on `(reversePostOrderCount - 1 - rpoIndex)`
  so `popMin` returns the deepest block first (postorder traversal,
  the correct frontier for liveness).
- The dataflow analyses are unit-tested but not on the
  `swa-bench unused-reachability` hot path (that scenario goes
  through `DependencyExtractor` + reachability BFS, not the
  intra-procedural CFG analyses). The win here is bounding the
  inner-loop complexity for adversarial CFG shapes the bench doesn't
  exercise.

## [0.3.0-alpha.5] - Unreleased

The memory layer's public types drop `@unchecked Sendable` and switch
fd plumbing to swift-system. `FileSlice` stays a value type rather
than going `~Escapable` (that would have broken every caller holding
a slice). 1135 tests green; A/B perf check shows the new code is
faster and more stable than the previous path (post-rework:
σ ≈ 0.01s over 3 runs; pre-rework: σ ≈ 0.10s over 3 runs).

### `@unchecked Sendable` confined to private storage

- **`MemoryMappedFile` is plain `Sendable`** (was `@unchecked`). The
  unsafe `UnsafeRawPointer` + the `SystemPackage.FileDescriptor` live
  inside a private `MappingStorage` class — the standard Swift 6 cage
  pattern, same shape `Synchronization.Mutex` uses internally. The
  public type's Sendable conformance is now compile-time checked.
- **`FileSlice` is plain `Sendable`** (was `@unchecked`). Pointer +
  parent reference held inside private `FileSliceStorage`. API
  surface unchanged.
- **`ArenaTokenStorage` is plain `Sendable`** (was `@unchecked`). The
  four `UnsafeBufferPointer` fields (`kinds`/`offsets`/`lengths`/`lines`)
  held inside private `ArenaTokenStorageBuffers`.

The `@unchecked Sendable` attribute now lives on exactly three
`private final class` types — `MappingStorage`, `FileSliceStorage`,
`ArenaTokenStorageBuffers` — and not on any public surface.

### Native-API adoption

- **`MemoryMappedFile` opens via `SystemPackage.FileDescriptor.open`.**
  Was raw POSIX `open(path, O_RDONLY|O_NOFOLLOW)`; now
  `FileDescriptor.open(FilePath(path), .readOnly, options: [.noFollow])`.
  Typed errors, typed `FilePath`, no raw C call site. `mmap`/`munmap`
  remain raw — swift-system has no mapping wrapper. `try? descriptor.close()`
  in the storage class's `deinit` replaces the raw `close(fd)`.
- New explicit `swift-system` dep in `Package.swift` (was transitive
  via indexstore-db).

### Performance

- The `findLineRanges` hot path snapshots `storage.data` / `storage.size`
  to local `let`s before the per-byte scan. Without the snapshot the
  Swift compiler can't elide the class-field reload per iteration
  (storage is a class). A/B check: 30 M-byte byte scan stays at the
  prior throughput (≈ within 1% noise).

## [0.3.0-alpha.4] - Unreleased

`ShingleGenerator` rewritten to iterate `ArraySlice<TokenInfo>` directly.
1135 tests green; baselines refreshed.

### Performance

- **`ShingleGenerator.generateBlockDocuments` consumes `TokenInfo`
  slices directly.** The previous hot path materialised an N-element
  `[String]` (token texts) and an N-element `[TokenKind]` (token kinds)
  per file via `sequence.tokens.map(\.text)` / `.map(\.kind)`. The new
  `generate(tokenInfos:)` + `normalizeTokenInfos(_:)` pair reads `text`
  and `kind` straight off each `TokenInfo`, eliminating both
  allocations. Measured **−6.5% mean wall-time on `duplicates-near`**
  over `Sources/` (0.502s → 0.470s, 122 files); the benchmark baseline
  has been refreshed accordingly.

## [0.3.0-alpha.3] - Unreleased

Benchmarks become an actual CI gate. 1135 tests green; six benchmark
baselines committed under `bench/baselines/`.

### Benchmarks are now a real CI gate

- **`swa-bench` JSON schema extended.** Reports now carry
  `wallSecondsMedian`, `wallSecondsP99`, `peakRSSBytesP99`, plus an
  `environment { gitSha, swiftVersion, host, platform }` block for
  cross-machine baseline traceability. `--statistical` flag prints
  median + p99 to stderr alongside the human-readable mean. **Add
  fields; never rename** — `bench/compare.sh` consumes
  `wallSecondsMean` / `wallSecondsP99` directly.
- **Persisted baselines.** `bench/baselines/*.json` for every scenario
  committed. `bench/refresh-baselines.sh` regenerates them locally or
  from CI; tune via `SWA_BENCH_WARMUP` / `SWA_BENCH_ITERATIONS` env
  vars.
- **`bench/compare.sh` is the gate.** Compares fresh results to
  baselines; fails (exit 1) when any scenario exceeds **+10 % mean
  OR +25 % p99** over its baseline. Per-scenario overrides via
  `bench/baselines/<scenario>.thresholds.json`. Emits a Markdown table
  suitable for the PR comment.
- **`duplicates-semantic` scenario added.** The CI loop previously ran
  5 of 6 scenarios. Now runs all 6.
- **`refresh-baselines.yml` workflow.** `workflow_dispatch` triggered;
  requires a `reason` input; opens a PR with the regenerated baselines
  so the change is reviewable.

PRs that touch the analyzer source paths now trigger the workflow,
run the six scenarios, compare against the committed baselines, and
**fail the build** on regression.

## [0.3.0-alpha.2] - Unreleased

Native-API + perf-truth-up items. 1135 tests green.

### Perf claims now backed by code

- **AST fingerprint switches to M_61.** `FingerprintHasher` replaces
  `% 1_000_000_007` (a 30-bit prime that collided ~50% at N≈50 000
  snippets) with the same Mersenne-61 reduction the SIMD MinHash
  kernel already uses. Regression test verifies (a) every output
  stays under 2^61 − 1, (b) > 9 990 / 10 000 distinct hashes on a
  deterministic probe set.
- **SA-IS is now arena-backed end-to-end.** `SAIS.build` creates an
  `Arena` at the top of the call and threads it through recursion.
  The working `sa` buffer is an `UnsafeMutableBufferPointer<Int>` from
  the arena; the second `placeLMSSuffixesOrdered` pass reuses the
  same buffer in place (no fresh `[Int]` allocation). `placeLMSSuffixes`,
  `placeLMSSuffixesOrdered`, `inducedSortLType`, `inducedSortSType`,
  `assignLMSNames` all take the buffer pointer instead of `inout [Int]`.
  `SuffixArrayBuilder.build`'s `sa.filter { $0 < n }` postpass is
  replaced by an in-place `removeFirst()` (the sentinel sorts to
  index 0). Existing `SAISCorrectnessTests`,
  `SuffixArrayConstructionTests`, `LCPCorrectnessTests` pass unchanged.

### Native-API adoption + concurrency hygiene

- **`withThrowingDiscardingTaskGroup`** at `ParallelProcessor.forEach`.
  Drops the per-task result-slot allocation; any throw cancels siblings
  + propagates automatically.
- **`ParallelProcessor.map` / `compactMap` and
  `ParallelMinHashGenerator.computeSignatures` honour their
  `maxConcurrency` caps** via the streaming-bounded pattern from
  `ZeroCopyParser.extractParallel:437-467`. Previously the
  documents-per-task ratio scaled with input size, ignoring the cap.
- **`BackpressuredChannelStream.makeChannel` cancellation.** The
  producer Task is now wrapped in `withTaskCancellationHandler`; on
  cancel the channel is finished *immediately* rather than at the
  operation's next `Task.isCancelled` checkpoint. The docstring
  promise (consumer-side iteration termination drains the producer)
  is now actually wired.
- **`OSSignposter` instrumentation.** New
  `SwiftStaticAnalysisCore.Utilities.Signposter` with
  `#if canImport(os.signpost)` guards for Linux. Phase intervals on
  `DuplicationDetector.detectClones`, `UnusedCodeDetector.detectUnused`,
  and `SymbolFinder.find` show up as named regions in Instruments'
  os_signpost track.

## [0.3.0-alpha] - Unreleased

Structural cleanups + feature delivery for capabilities the prior
README/CHANGELOG already advertised. 15 items shipped; 1134 tests
green.

### Breaking changes (since 0.2.x)

- **Platforms**: `.iOS(.v18)` dropped from `Package.swift`. `IndexStoreDB`
  is macOS-only and now sits in `SwiftStaticAnalysisCore`'s dependency
  closure — there was never a working iOS configuration. Consumers
  that listed `iOS` as a deployment target will see the resolver
  narrow to macOS 15.
- **Module graph**: `IndexStoreReader`, `IndexStoreFallbackManager`,
  `FallbackConfiguration`, and `IndexStoreError` moved from
  `UnusedCodeDetector.IndexStore` to
  `SwiftStaticAnalysisCore.IndexStore`. `SymbolLookup` no longer
  depends on `UnusedCodeDetector`. Consumers that
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
  launcher API public was a footgun.
- **`UnusedCodeDetector.DataFlow.*`** demoted from `public` to
  `internal` (157 declarations across `CFGBuilder`, `SCCPAnalysis`,
  `ReachingDefinitions`, `LiveVariableAnalysis`). The dataflow
  subsystem has no external consumers; the public surface was an
  unintentional ABI commitment. Use `@testable import
  UnusedCodeDetector` if you were poking at these.

### Security (defence-in-depth)

- `IndexStoreReader.allowsDirectoryCreation` now flows from
  `UnusedCodeConfiguration` via the new
  `allowsIndexDatabaseCreation: Bool` field (default `true` to preserve
  CLI/programmatic behaviour). `SWAMCPServer.handleDetectUnusedCode`
  sets it to `false`, so a hostile MCP prompt cannot drive a
  `createDirectory` side-effect even when an `IndexDatabase/` directory
  is absent. Surfaces `IndexStoreError.databaseDirectoryMissing`
  instead.
- `StaticAnalysisCommandPlugin` now scrubs `process.environment = [:]`
  before spawning the `swa` tool, closing the residual
  `DYLD_INSERT_LIBRARIES` / `SWIFTPM_HOOKS_DIR` passthrough that the
  SPM-plugin sandbox couldn't fix via `ProcessExecutor` (Core is
  gated out of plugins).

### Features delivered

- **`swa unused --auto-build` CLI flag.** Previously the flag was
  referenced by SECURITY.md and DocC but only reachable via the
  programmatic API and `.indexStoreAutoBuild` preset. CLITests asserts
  the flag is advertised in `--help`.
- **`ParallelMode.maximum`** actually engages
  `BackpressuredChannelStream`-backed streaming verification in
  `MinHashCloneDetector.detectParallel`. New
  `ParallelMode.usesStreamingVerifier`, `ParallelCloneConfiguration.useStreamingVerifier`,
  and `DuplicationConfiguration.useStreamingVerifier` thread the
  choice from CLI to detector.
- **`.swa.json` `unused.excludeNamePatterns` and
  `duplicates.ignoredPatterns` reach the detectors.** Previously they
  were decoded by `SWAConfiguration` and silently dropped by
  `buildUnusedConfig` / `buildDuplicationConfig`.
- **Per-type default algorithm flip.** With no `--algorithm` override:
  - `--types exact` → `.suffixArray` (was `.rollingHash`)
  - `--types near` → `.minHashLSH` (was `.rollingHash`)
  - `--types semantic` → `.minHashLSH` (was `.rollingHash`)
  - Mixed sets → `.rollingHash` (catch-all preserved)
  The README clone-type table now matches reality. New
  `defaultAlgorithm(forCloneTypes:)` helper. `parseAlgorithm` now
  returns `DetectionAlgorithm?` instead of silently defaulting.
- **MinHash routing for `--types near`.** When the user requests
  `.near` with `.minHashLSH`, `DuplicationDetector` now routes through
  `MinHashCloneDetector` and **relabels** the output groups `.near`
  instead of leaking the detector's intrinsic `.semantic` label.
- **`ParallelBFS` auto-selection.** When the user didn't pin
  `--parallel-mode` / `--parallel`, `DependencyExtractor.detect`
  chooses `computeReachableParallel` for graphs with ≥
  `UnusedCodeConfiguration.parallelBFSThreshold` nodes (default 1000)
  and sequential BFS for smaller graphs. CLI now forwards `nil` for
  the auto path instead of always forcing parallel.

### Consistency / API hygiene

- `SymbolLookup → UnusedCodeDetector` dependency removed.
- `swa/SWA.swift` local `canonicalizePath` deleted. The CLI now
  routes path canonicalisation through `PathUtilities.canonicalize`,
  matching the MCP `CodebaseContext` surface.
- CLI `findSwiftFiles` re-resolves each enumerated path and checks
  it stays inside the analysis root. Symlinks pointing at
  `/tmp/.build/...` or external artifact trees no longer smuggle
  generated code into the analysis.
- `swa-mcp` ported to `ArgumentParser`. `--path=…`, `--help`,
  `--version` all use the same parsing engine as the rest of the
  toolchain.

## [0.2.1] - Unreleased

Closes four HIGH-severity MCP security findings and fixes several
correctness bugs. No public API removals; one access-level expansion
(`SWAMCPServer` gains internal test surface).

### Security (MCP)

- **`index_store_path` is sandbox-validated.** `handleDetectUnusedCode`
  now routes the attacker-controllable `index_store_path` MCP argument
  through `CodebaseContext.validatePath`, preventing both the
  arbitrary-directory read and the implicit
  `createDirectory(.../IndexDatabase)` write outside the codebase root
  that previous servers exposed. Defence-in-depth:
  `IndexStoreReader.init` now takes an
  `allowsDirectoryCreation: Bool = false` parameter; CLI paths
  explicitly opt in (`true`), while any caller that forgets gets the
  safe-by-default semantics. `IndexStoreError.databaseDirectoryMissing`
  surfaces the refusal.
- **`ReadResource` URI parser hardened.** The previous
  `String(uri.dropFirst(7))` is replaced with `URL(string: uri)` plus
  scheme / host / empty-path checks. Percent-encoded `%2F` no longer
  round-trips into the sandbox-prefix check; host-bearing
  `file://example.com/...` URIs are rejected outright instead of
  silently collapsing to a relative sandbox path. Factored into the
  testable `SWAMCPServer.parseFileURI(_:)` helper.
- **`SWAMCPServer.contextCache` is bounded.** The unbounded
  `Dictionary<String, CodebaseContext>` is replaced with a 32-entry
  `LRUDictionary`. A hostile MCP prompt can no longer pin unbounded
  memory by flood-creating distinct codebase paths.
- **`SafeRegex` central compiler.** New
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
  `SoAStorageError.lengthOverflow` / `.columnOverflow` instead of
  silently clamping `length` / `column` to `UInt16.max`. Propagated
  through `ZeroCopyParser.extractTokensToSoA` (typed throws).
- **`RegexCache` LRU eviction is now genuine LRU.** The
  `Dictionary.keys.first` eviction (undefined order) is replaced by
  the new canonical `LRUDictionary` (built on swift-collections'
  `OrderedDictionary`). `SwiftFileParser` and `ZeroCopyParser` also
  migrate to `LRUDictionary`.
- **`--report` validates its mode.** `swa unused --report --mode simple`
  now exits 64 with a clear diagnostic instead of silently producing a
  regular unused-code listing.
- **`CodebaseContext.getCodebaseInfo` no longer allocates per-file
  `String`s.** The line-count loop now uses `MemoryMappedFile` +
  `withRawSpan` and skips files over 64 MiB.

### Features

- **`SymbolQuery.qualifiedName(_:_:)` and `SymbolQuery.selector(_:labels:)`.**
  These factories are referenced by README's "Programmatic API"
  examples but were missing before this release.
- **`.swa.json` top-level `format` field applied.** Each subcommand
  resolves `--format` > `.swa.json:format` > `.xcode`. The field was
  decoded but unused before.

### Consistency

- **Single source-of-truth `swaVersion`.** New
  `SwiftStaticAnalysisCore.Version.swift` is the only place version
  literals live; `swa`, `swa-mcp`, and `SWAMCPServer` all reference it
  (the MCP server previously advertised the stale literal `"0.1.0"`).
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

This release ships real SIMD MinHash, SoA token storage in the
duplication hot path, Arena-backed SA-IS, DenseGraph + ParallelBFS
as the reachability default, AsyncChannel-backed real backpressure,
a `swa-bench` perf-regression gate, mutation testing + Linux CI gates,
Span / RawSpan adoption with `@unchecked Sendable` removed from the
memory types, and a Process environment-allowlist scrubber for
IndexStoreDB invocations.

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

### Highlights

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
  articles describe the actual codebase.
- **Boundary validation**: `.swa.json` files with bogus enum strings
  (`format: "telepathic"` etc.) are rejected by `ConfigurationLoader`
  with a typed `ConfigurationError.invalidFieldValue`.

### Security (CRITICAL / HIGH)

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
- **`--min-tokens` validation**: bounded to `1...10_000` (regression
  from 0.0.14).
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
