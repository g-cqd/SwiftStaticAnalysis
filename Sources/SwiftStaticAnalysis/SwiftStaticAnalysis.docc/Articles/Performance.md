# Performance

What every advertised performance feature actually does, and where it
sits in the codebase. Numbers in this article come from `swa-bench`
runs on this repository's own `Sources/` directory.

## Overview

The framework's perf model is built around four pillars:

1. **Memory-mapped I/O** for every parser hot path.
2. **Bounded LRU caches** so long-running MCP sessions stay within
   memory and file-descriptor budgets.
3. **Dense reachability** with bit-packed visited tracking and an
   optional parallel direction-optimising BFS.
4. **Real SIMD** for MinHash signatures, with Mersenne-prime modulus
   so reduction is branch-free across SIMD lanes.

## Memory-mapped I/O

`Sources/SwiftStaticAnalysisCore/Memory/SourceFileReader.swift` is the
single entry point for source reads. Files ≥ 4 KiB go through
`MemoryMappedFile` (with `O_NOFOLLOW` on Darwin, a 256 MiB cap, and a
regular-file `fstat` check). Smaller files use the standard
`String(contentsOfFile:)` path because mmap setup overhead would
dominate.

The following hot paths route through `SourceFileReader`:

- `SwiftFileParser.parse(_:)` (every detector goes through this)
- `_DuplicationEngine.addCodeSnippets`
- `DuplicationDetector.extractTokenSequences`
- `MinHashCloneDetector.detect(in:)`
- `IncrementalDuplicationDetector.detect(in:)`
- `IgnoreDirectiveScanner.scan(files:)`
- `FileContentCache.content(for:)`
- `SymbolContextExtractor.readFile(_:)`
- `AccessLevelExtractor.extractAccessLevel(...)`

The MCP `read_file` and `ReadResource` handlers stay on
`String(contentsOfFile:)` after the regular-file / extension / size
allow-list (10 MiB cap) — `read_file` is a tool API call, not a hot
path, and the size cap keeps it small enough that mmap setup would be
counterproductive.

## Bounded LRU caches

`SwiftFileParser` and `ZeroCopyParser` cap their syntax-tree caches at
256 and 64 entries respectively. The cache uses
`OrderedDictionary<String, Cached>` from swift-collections, so eviction
and recency-touch are both O(1). Cache keys are canonicalised through
`PathUtilities.canonicalize` so two spellings of the same file share
one entry.

This closes the OOM / fd-exhaustion risk for long-running MCP sessions
that analyse different codebases over a single server lifetime.

## DenseGraph + Parallel BFS

`IndexBasedDependencyGraph` and `ReachabilityGraph` both project their
string-keyed adjacency lists onto a `DenseGraph` (contiguous integer
indices) lazily on the first reachability query. Sequential BFS uses
`swift-collections.BitArray` for visited tracking; the inner loop no
longer hashes USR strings.

For graphs with ≥ 1000 nodes, `ParallelBFS.computeReachable` runs the
Beamer-style direction-optimising BFS (top-down → bottom-up switch
based on the α/β heuristic) with `AtomicBitmap` for lock-free visited
tracking and `BitArray` for the bottom-up frontier (built once per
super-step under the structured-concurrency `let`-binding so the
worker closures capture an immutable value).

## Real SIMD MinHash

`MinHash.computeSignatureSIMD` uses `SIMD4<UInt64>` lanes with the
Mersenne prime `M_61 = 2^61 − 1` as the universal-hashing modulus.
Reduction collapses to `(r & M_61) + (r >> 61)` plus one fold —
branch-free, fully vectorisable. Coefficients are generated via
SplitMix64 (replaces the previous LCG-derived mixer).

The scalar and SIMD paths are bit-identical; the equivalence is
asserted by `MinHashSIMDEquivalenceTests` in
`Tests/DuplicationDetectorTests/`.

## SA-IS memory layout

The Suffix Array constructor uses `swift-collections.BitArray` for its
S-type / L-type classification vector. That's 1 bit per suffix where
a `[Bool]` would be 1 byte per suffix — 8× memory saving on the
classification step for codebases with millions of tokens.

The working `sa` buffer is arena-allocated as an
`UnsafeMutableBufferPointer<Int>` rather than a per-recursion `[Int]`.
A single `Arena` lives at the top of `SAIS.build` and grows as
recursion deepens; the second `placeLMSSuffixesOrdered` pass reuses the
buffer in place. The generic-`T` migration (`UInt32` indices instead of
`Int`) is on the roadmap.

## Streaming

The framework has two streaming primitives:

- `TaskBackedAsyncStream.makeStream`: `AsyncStream` backed by a producer
  task. Default buffering policy is `.bufferingNewest(256)` — i.e.
  "buffer and drop oldest under overflow". Use when the consumer is
  uniformly fast and dropped elements are acceptable.
- `BackpressuredChannelStream.makeChannel`: `AsyncChannel`-backed.
  Producer suspends on `await channel.send(_:)` when the consumer
  hasn't drained — true backpressure. Use when dropping a result loses
  expensive work (e.g. a verified clone pair).

`StreamingVerifier` exposes both: `streamResults` (buffered) and
`streamResultsBackpressured` (rendezvous).

## Benchmark harness

The `swa-bench` executable runs the perf scenarios end-to-end and
emits a JSON report. The `.github/workflows/benchmarks.yml` workflow
runs it on PRs that touch analyser code and posts a summary table.

```bash
swift run -c release swa-bench duplicates-exact Sources --warmup 1 --iterations 3
```

The artifact contains per-iteration wall time and peak RSS samples
plus the per-scenario means.
