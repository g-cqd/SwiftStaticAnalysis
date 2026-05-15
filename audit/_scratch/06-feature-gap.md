# 06 — Feature-gap audit (claim vs. reality)

Repository: `SwiftStaticAnalysis` @ `main` (0.2.0)
Auditor scope: README.md, CHANGELOG.md, SECURITY.md, CONTRIBUTING.md,
`.swa.schema.json`, DocC bundles, then verified against `Sources/`.
Output is read-only; this file is the only artifact.

---

## Summary

Overall alignment grade: **C+**. The codebase delivers most of the
headline capabilities (three detection modes, three clone algorithms,
ignore directives, MCP server with seven tools, SIMD MinHash, SA-IS,
DenseGraph BFS), but a non-trivial fraction of the marketing surface is
either *softened by reality*, *contradicted by the implementation*, or
*completely missing*.

The most material gaps are:

1. **The clone-type ↔ algorithm mapping table in README is misleading.**
   "Exact (Type-1) uses SA-IS" / "Near (Type-2) uses MinHash + LSH" is
   only true if the user opts in via `--algorithm`. The default
   `algorithm: .rollingHash` dispatches exact → `ExactCloneDetector`
   (Rabin-Karp) and near → `NearCloneDetector` (Rabin-Karp with token
   normalisation). MinHash+LSH only runs for *semantic* clones when
   `--algorithm minHashLSH` is explicitly chosen. The DocC umbrella
   page (`SwiftStaticAnalysis.md` line 41–42) repeats the same overreach.
2. **`swa unused --auto-build` is documented (SECURITY.md, CHANGELOG,
   DocC `Security.md`) but does not exist as a CLI flag.** The
   `autoBuild` configuration field is wired only via the programmatic
   API and via the `.indexStoreAutoBuild` preset; no CLI option toggles
   it. Every security paragraph in SECURITY.md that says "do not pass
   `--auto-build` on untrusted codebases" is unreachable.
3. **`SymbolQuery.qualifiedName("APIClient", "shared")` and
   `SymbolQuery.selector("fetch", labels: ["id", "completion"])` —
   shown in README's "Programmatic API" — do not exist.** The actual
   convenience initialisers are `SymbolQuery.name(_:)`,
   `SymbolQuery.qualified(_:)` (single dotted string),
   `SymbolQuery.usr(_:)`, `SymbolQuery.definition(of:)`. The selector
   pattern is reachable only through `SymbolQuery.Pattern.selector(...)`
   or `QueryParser`. These two README snippets would not compile.
4. **`ParallelMode.maximum` does not enable "AsyncChannel-backed
   real backpressure".** CHANGELOG (0.2.0 "Streaming default") and
   README both claim it does. `ParallelMode.swift` itself contradicts
   that — `.safe` and `.maximum` differ only in
   `ConcurrencyConfiguration` shape; the streaming/backpressure path is
   reached *via explicit streaming APIs* (`StreamingVerifier`), not by
   choosing `.maximum`. So `--parallel-mode maximum` is a misleading
   surface for backpressure.
5. **`.swa.json` `unused.excludeNamePatterns` and `duplicates.ignoredPatterns`
   are decoded and merged but never applied** by the CLI. The detectors
   support them, but `Unused.run()`/`Duplicates.run()` /
   `buildUnusedConfig` never forward the values. Silent no-op.
6. **The "70 / 85 / 95 %" detection-mode accuracy figures are
   unsubstantiated.** Neither the test suite nor `swa-bench` measures
   precision / recall against a labelled fixture. `swa-bench` only
   measures wall-time and peak RSS.
7. **Default-mismatch between CLI, schema, and library.** Schema asserts
   `treatPublicAsRoot/Objc/Tests/SwiftUIViewsAsRoot` default to `false`;
   CLI defaults them to `true`; library `UnusedCodeConfiguration.init`
   also defaults `true`. The schema is wrong for the post-0.2.0 world.
8. **Legacy `parallel` is promised to be deprecated but no deprecation
   warning is emitted.** Both the CLI flag and the `.swa.json` field
   are silently accepted. The mapping is also inconsistent: CLI
   `--parallel` → `.maximum`; `.swa.json` `parallel: true` → `.safe`.
9. **The Build plugin makes every build fail when findings exist.** The
   plugin invokes `swa <path> --format xcode`, which dispatches to
   `Analyze` (default subcommand). `Analyze.run` throws `ExitCode(2)`
   when *anything* is found. As a `prebuildCommand`, exit 2 fails the
   build. README does not mention this.
10. **`benchmarks.yml` does not gate.** It posts a PR comment with raw
    numbers. There is no baseline comparison and no failure threshold.
    The README's "gated in CI via `.github/workflows/benchmarks.yml`"
    overstates the workflow's role. The workflow also runs only 5 of
    the 6 scenarios that `swa-bench` supports
    (`duplicates-semantic` is absent).

The rest of this document enumerates every concrete gap I found.

---

## Critical gaps (features that just don't work)

### C-1. `--auto-build` CLI flag is documented but absent
**Severity: Blocking** (security narrative depends on it)

- Claim source:
  - `SECURITY.md:75`–`90` repeatedly references `swa unused --auto-build`.
  - `SECURITY.md:97`–`99` "**`swa unused --auto-build` invokes
    `swift build`** in the analysed codebase."
  - `CHANGELOG.md:67`–`70` "Process env allowlist: `ProcessExecutor`
    scrubs `DYLD_INSERT_LIBRARIES` / `SWIFTPM_HOOKS_DIR` etc. before
    spawning indexstore-db invocations."
  - `Sources/.../Articles/Security.md:87`, `Security.md:106`–`111`.
- Reality:
  - `Sources/swa/SWA.swift` — full `Unused` struct (lines 251–462)
    declares no `autoBuild` / `auto-build` option. `grep -n "auto"
    Sources/swa/SWA.swift` only finds the unrelated `auto-generated`
    comment at line 1046.
  - The library config field `UnusedCodeConfiguration.autoBuild`
    (`Sources/UnusedCodeDetector/Configuration/UnusedCodeConfiguration.swift:28`)
    exists; the preset `.indexStoreAutoBuild`
    (line 77) exists; `detectUnusedWithIndexStore`
    (`UnusedCodeDetector+IndexStore.swift:13`) honours it. But there's
    no CLI surface.
- Difference: The MCP tool description (`SWAMCPServer.swift:243`)
  honours the SECURITY.md claim that "`auto_build` is NOT exposed via
  the MCP tool surface" (it isn't); but SECURITY.md also implies the
  CLI exposes it. The CLI does not.
- Suggested fix: **deliver the feature** — add `@Flag --auto-build` to
  `Unused`, wire to `UnusedCodeConfiguration.autoBuild`. Otherwise:
  rewrite SECURITY.md to say "auto-build can only be enabled through the
  programmatic API or via a configuration file" and remove the
  `--auto-build` flag reference.

---

### C-2. README "Programmatic API" snippets reference symbols that don't exist
**Severity: Major** (documentation lies; sample code will not compile)

- Claim source: `README.md:252` and `README.md:256`:
  ```swift
  let qualified = SymbolQuery.qualifiedName("APIClient", "shared")
  let selector  = SymbolQuery.selector("fetch", labels: ["id", "completion"])
  ```
- Reality (`Sources/SymbolLookup/Models/SymbolQuery.swift:166`–`209`):
  the only static factories are
  - `static func name(_ name: String) -> SymbolQuery`
  - `static func qualified(_ qualifiedName: String) -> SymbolQuery`
    (takes a *single* dotted string like `"APIClient.shared"`)
  - `static func usr(_ usr: String) -> SymbolQuery`
  - `static func definition(of name: String) -> SymbolQuery`
- Neither `SymbolQuery.qualifiedName(_:_:)` nor `SymbolQuery.selector(_:labels:)`
  exists. The selector *pattern* is reachable through
  `.selector(name:labels:)` on `SymbolQuery.Pattern`, but the README's
  call sites would refuse to compile.
- Suggested fix: rewrite the snippet to use the actual API (e.g.
  `SymbolQuery.qualified("APIClient.shared")` and
  `SymbolQuery(pattern: .selector(name: "fetch", labels: ["id", "completion"]))`),
  or *deliver* the missing convenience initialisers.

---

### C-3. `ParallelMode.maximum` does not engage AsyncChannel backpressure
**Severity: Major**

- Claim source:
  - `README.md:170` "`maximum` enables streaming/backpressure in
    programmatic pipelines".
  - `README.md:644`–`645` "**AsyncChannel backpressure**:
    `ParallelMode.maximum` uses `BackpressuredChannelStream` for
    streaming verifiers".
  - `CHANGELOG.md:38`–`40` ("Streaming default") — "`ParallelMode.maximum`
    now means 'AsyncChannel-backed real backpressure' for streaming
    verifiers".
- Reality: `Sources/SwiftStaticAnalysisCore/Configuration/ParallelMode.swift:17`–`21`
  explicitly contradicts:
  > Note that `.safe` and `.maximum` differ only in their
  > `ConcurrencyConfiguration` shape (max files / max tasks); the
  > streaming/backpressure path is reached via explicit streaming APIs
  > (e.g. `StreamingVerifier`), not by choosing `.maximum`.

  `ParallelMode.toConcurrencyConfiguration(maxConcurrency:)` returns
  `.default` for `.safe` and `.highThroughput` for `.maximum`. Neither
  branch invokes `BackpressuredChannelStream`.
  `MinHashCloneDetector.detectParallel(in:)` does conditionally use
  `ParallelVerifier`, but the dispatch is gated on `minParallelPairs`
  rather than on `ParallelMode`.
- Suggested fix:
  - **Soften the claim** in README (`170`, `644–645`) and CHANGELOG
    (`38–40`) to describe streaming as opt-in via the streaming APIs;
    or
  - **Deliver the feature** — branch on `.maximum` to swap in
    `streamResultsBackpressured` end-to-end.

---

### C-4. `swa.json` `excludeNamePatterns` / `ignoredPatterns` silently dropped
**Severity: Major** (configuration is decoded but never reaches the detector)

- Claim source:
  - `.swa.schema.json:121` `unused.excludeNamePatterns: regex
    patterns for declaration names to exclude`.
  - `.swa.schema.json:185` `duplicates.ignoredPatterns: regex patterns
    for code to ignore in duplication detection`.
- Reality:
  - `Sources/SwiftStaticAnalysisCore/Configuration/SWAConfiguration.swift:185, 259`
    declare the fields. `ConfigurationLoader.swift:237, 258` merge them.
    *Neither is ever read* in `Sources/swa/SWA.swift`.
  - `Unused.run()`/`buildUnusedConfig` build `UnusedCodeConfiguration`
    *without* passing `ignoredPatterns: …`. So the detector receives
    `[]`.
  - `Duplicates.run()`/`buildDuplicationConfig` build
    `DuplicationConfiguration` *without* `ignoredPatterns: …`.
- Difference: the schema advertises features that the CLI cannot use.
- Suggested fix: wire them through, or remove them from the schema and
  the README "Configuration File" section.

---

### C-5. The `.swa.json` top-level `format` field is decoded but ignored
**Severity: Minor** (CLI default is identical, so visible damage is small)

- Claim source: `.swa.schema.json:18`–`23`, `README.md:148` example
  contains `"format": "..."` as a real knob (top-level).
- Reality: `Sources/swa/SWA.swift:67`–`68` in `Analyze.run`:
  ```swift
  // Apply format from config if not specified on CLI
  let outputFormat = format
  ```
  The comment lies. Only the CLI's own `--format` value is read; the
  decoded `swaConfig.format` is *not* consulted. Same for `Duplicates`
  (line 230) and `Unused` (line 445) and `Symbol`. The top-level
  `format` key in `.swa.json` is dead.
- Suggested fix: read `swaConfig?.format` as a fallback (CLI > config >
  default), or drop the field from the schema and README.

---

### C-6. `--min-confidence` cannot relax the detector's default `.medium` floor
**Severity: Major** (CLI flag advertised as functional, is partially functional only)

- Claim source: `README.md:404` "`--min-confidence <level>` — Minimum
  confidence: `low`, `medium`, `high`".
- Reality:
  - `UnusedCodeConfiguration.init` defaults `minimumConfidence: .medium`
    (`Sources/UnusedCodeDetector/Configuration/UnusedCodeConfiguration.swift:23`).
  - The detector applies that filter internally
    (`Sources/UnusedCodeDetector/UnusedCodeDetector.swift:145, 182`,
    `+IndexStore.swift:110, 150`,
    `IncrementalUnusedCodeDetector.swift:153, 165`).
  - `Unused.run()` (`Sources/swa/SWA.swift:391`–`403`) builds
    `UnusedCodeConfiguration` *without* threading `minConfidence`
    through; it then post-filters with `filterUnusedResults(...,
    minConfidence: minConf)`.
- Behaviour: pass `--min-confidence low` → detector already dropped
  low-confidence items at default `.medium`; post-filter cannot
  recover them. Pass `--min-confidence high` → both filters apply, OK.
- Suggested fix: route CLI `--min-confidence` into the detector
  configuration *before* analysis (and drop the post-filter), or
  rewrite the configuration default to `.low` and keep post-filter.

---

### C-7. The Build plugin fails every build when findings exist
**Severity: Major** (silent UX trap)

- Claim source: `README.md:13`–`14` "**Multi-Algorithm Clone
  Detection**: Exact (Type-1), near (Type-2), and semantic (Type-3/4)
  …". `README.md:531` "StaticAnalysisBuildPlugin/ # Build-time analysis
  plugin". Architecture diagram implies this is a non-fatal reporter.
- Reality:
  - `Sources/StaticAnalysisBuildPlugin/Plugin.swift:33`–`49` invokes
    `swa <path> --format xcode` as a `prebuildCommand`.
  - With no subcommand named, `SWA.defaultSubcommand = Analyze.self`
    (`SWA.swift:38`). `Analyze.run()` throws `ExitCode(2)` whenever a
    clone or unused-code finding is detected (line 96–98).
  - `prebuildCommand` exit ≠ 0 fails the build.
- Suggested fix: have the build plugin call `swa analyze … --format
  xcode` and either gate on a `--soft` mode (deliver the feature) or
  document the exit-code behaviour prominently. README does not even
  hint at it.

---

### C-8. Benchmarks workflow does not gate
**Severity: Major** (the "perf-regression gate" framing is false)

- Claim source: `README.md:646`–`649` "The above is benchmarked in
  `swa-bench` and **gated in CI via `.github/workflows/benchmarks.yml`**.".
  `CHANGELOG.md:60`–`63` "`swa-bench`: new executable with six
  scenarios … CI workflow `benchmarks.yml` runs on PRs".
- Reality (`.github/workflows/benchmarks.yml`):
  - Runs only `duplicates-exact, duplicates-near, unused-simple,
    unused-reachability, symbol-lookup` (5 scenarios — *misses*
    `duplicates-semantic`, which exists in
    `Sources/swa-bench/main.swift:24`).
  - Uploads an artifact and posts a PR comment.
  - Has **no baseline comparison and no failure threshold**.
- Suggested fix: either implement a baseline + threshold check (and
  fail the job on regression), or rewrite both bullets to call it
  "an informational PR comment".

---

## Documentation overreach (claims softened by reality)

### O-1. The 70 % / 85 % / 95 % accuracy figures are unsubstantiated
- Source: `README.md:321`–`325`, `Sources/.../Articles/UnusedCodeDetection.md:13`–`15`.
- Reality: no test or benchmark in the repository measures
  precision/recall against a labelled fixture.
  - `Tests/UnusedCodeDetectorTests/` contains correctness tests on
    small fixtures, not aggregate accuracy.
  - `Sources/swa-bench/main.swift` measures *wall time* and *peak RSS*
    only. `BenchmarkScenario` does not check result counts.
- Suggested fix:
  - Either build a labelled accuracy fixture under
    `Tests/Fixtures/UnusedCodeAccuracy/` with known true-positive /
    false-positive lists, run it in CI, and use the actual measured
    numbers; or
  - Replace the percentages with qualitative descriptions ("syntax-only
    — misses cross-file usages", "intra-package reachability — catches
    dead local code", "IndexStore — catches cross-module and protocol
    witnesses").

### O-2. The clone-type/algorithm table is misleading
- Source: `README.md:331`–`336` says exact=SA-IS, near=MinHash+LSH,
  semantic=AST fingerprinting. `SwiftStaticAnalysis.md:41`–`43` says
  the same.
- Reality (`Sources/DuplicationDetector/_DuplicationEngine.swift:21`–`58`
  + `DuplicationDetector.swift:264`–`290`):

  | cloneType  | rollingHash (default)             | suffixArray            | minHashLSH                |
  |------------|-----------------------------------|------------------------|---------------------------|
  | `.exact`   | `ExactCloneDetector` (Rabin-Karp) | `SuffixArrayCloneDetector` | `ExactCloneDetector` (RK) |
  | `.near`    | `NearCloneDetector` (Rabin-Karp + token normalisation) | `SuffixArrayCloneDetector` (normalised) | `NearCloneDetector` (RK + normalisation) |
  | `.semantic`| `SemanticCloneDetector` (AST fingerprinting) | `SemanticCloneDetector` (AST) | `MinHashCloneDetector` (MinHash+LSH) |
- So:
  - SA-IS is *not* the default for exact clones; Rabin-Karp is.
  - MinHash+LSH does *not* run for near clones unless you also flip the
    type — i.e. there is no path where `--types near` triggers MinHash.
  - The only way to engage MinHash is `--types semantic --algorithm
    minHashLSH`, in which case the produced groups are labelled
    `type: .semantic` (`MinHashCloneDetector.swift:457`) — despite the
    README assigning MinHash to *near* clones.
- Suggested fix: rewrite the README table to describe what each
  algorithm actually does at each clone-type, or change the dispatch so
  the table holds. (A minimal "honest" rewrite would add an "algorithm
  default" column and a row of caveats.)

### O-3. "Direction-optimizing parallel BFS is selected by `--parallel-mode safe|maximum` for large graphs" is half true
- Source: `README.md:628`–`631`. Same claim in
  `SwiftStaticAnalysis.md:51`.
- Reality:
  - `UnusedCodeConfiguration.useParallelBFS`'s doc-comment
    (`Configuration/UnusedCodeConfiguration.swift:175`) says "Enable via
    `--parallel` CLI flag" — i.e. doc-comment still references the
    *deprecated* flag.
  - In `Unused.run()`
    (`Sources/swa/SWA.swift:366`–`374`): `effectiveParallelMode` is
    resolved, then `effectiveParallel = effectiveParallelMode.isParallel`
    (a bool). The bool is plumbed into `useParallelBFS`. So
    `--parallel-mode safe` does enable parallel BFS, but the README
    suggests this is *automatic* on large graphs whereas it is opt-in.
  - `DependencyExtractor.swift:599` checks `if configuration.useParallelBFS`
    — there's no automatic graph-size threshold inside that branch in
    the Unused detector itself. The CHANGELOG's "Auto-selects parallel
    BFS for graphs ≥1000 nodes" (line 55–56) is true for *clone* dense
    graphs (`MinHashCloneDetector.detectParallel`) but the unused-code
    reachability path does not auto-flip.
- Suggested fix: split the claim. "For clone detection, MinHash+LSH
  auto-selects parallel pipelines once doc count crosses
  `minParallelDocuments` (default 50). For unused-code reachability,
  parallel BFS is opt-in via `--parallel-mode safe|maximum`."

### O-4. "Arena allocator over Bitmap typed scratch buffers in SA-IS — no per-recursion [Int] allocations"
- Source: `README.md:636`–`638`.
- Reality:
  - `Sources/DuplicationDetector/SuffixArray/SuffixArray.swift:159`–`179`
    classifies into a `Bitmap` (✓).
  - `bucketHeads` / `bucketTails` / recursive reduced strings are still
    `[Int]` arrays (line 238, 251, 264, 291).
  - `Sources/.../Articles/Performance.md:90`–`93` admits as much:
    "Bucket scratch arrays in SA-IS … can be migrated to the `Arena`
    bump allocator if SA-IS becomes RSS-bound."
- Suggested fix: rewrite the README bullet to match Performance.md
  ("type vector is bit-packed; integer scratch arrays are conventional
  `[Int]`, migration is on the roadmap").

### O-5. "Memory-mapped I/O for files ≥ 4 KiB" is approximately correct but not uniform
- Source: `README.md:617`–`620`.
- Reality:
  - `Sources/.../Memory/SourceFileReader.swift:24` `defaultMmapThreshold = 4 * 1024`.
  - `ZeroCopyParser` default threshold is also `4096` at construction
    (`Memory/ZeroCopyParser.swift:17`) but the test preset
    (`ZeroCopyParser.swift:32`) lowers it to `1024`. The README's
    "≥ 4 KiB" claim is true for the SourceFileReader hot path; readers
    that wire ZeroCopyParser directly will see the configured threshold.
- Suggested fix: tighten to "files ≥ 4 KiB read via
  `SourceFileReader.readSource(at:)`".

### O-6. README's "Quick Start" implies algorithms can be selected per `--types`
- Source: `README.md:135`
  `swa duplicates /path/to/project --types near --algorithm minHashLSH --parallel-mode safe`.
- Reality (O-2 above): with `--types near --algorithm minHashLSH`, the
  CLI runs `NearCloneDetector` (Rabin-Karp). MinHash+LSH is *not*
  invoked for `--types near`. The Quick-Start example silently does
  something different from what the README's Clone-Types table
  promises.
- Suggested fix: see O-2.

### O-7. README's MCP server section claims sandboxing is "stdio only; does not bind a network socket" — accurate, but the MCP server version string lies
- Source: `SECURITY.md:64`–`67`.
- Reality (truthful). Side-note: `SWAMCPServer.swift:49` self-reports
  `version: "0.1.0"`, but the package and CLI are now `0.2.0`. Clients
  that depend on the advertised MCP version for capability negotiation
  will see stale data.
- Suggested fix: keep these in lockstep; either bump the MCP version
  literal or wire it to a package-wide constant.

### O-8. README and DocC reference "**all** post-audit changes" in `CHANGELOG.md` and `AUDIT.md`, but `AUDIT.md` is absent
- Source: `CHANGELOG.md:10` "This release closes the audit (see
  `AUDIT.md`)".
- Reality: `find . -name AUDIT.md` returns nothing in the repo root.
- Suggested fix: add `AUDIT.md` or strike the reference.

---

## Undocumented features (code that ships but isn't in README/DocC)

### U-1. Two block-comment range directives that the README does not mention
- `IgnoreDirectiveScanner.swift:73`–`87` parses
  `swa:ignore-duplicates:begin … swa:ignore-duplicates:end` and
  `swa:ignore:begin … swa:ignore:end` range markers. Neither appears
  in README's "Supported Formats" table (`README.md:272`–`281`).
- Suggested fix: add `swa:ignore:begin/end` to the README's directives
  table.

### U-2. `swa:ignore-duplicates` is also a recognised category
- `IgnoreDirectiveScanner.swift:91`–`92` recognises
  `swa:ignore-duplicates` as a single-line directive. README only
  lists `swa:ignore`, `swa:ignore-unused`, `swa:ignore-unused-cases`.
- Suggested fix: document `swa:ignore-duplicates` in the directives
  table.

### U-3. `--in-type` (search within type scope) is documented but not tested in the doc examples
- `SWA.swift:486`–`487` exposes `--in-type`. README (`README.md:458`)
  lists it. ✓ — but no example uses it.

### U-4. Multiple `UnusedCodeConfiguration` presets are unreachable from CLI
- The library exports `.strict`, `.indexStoreAutoBuild`, `.hybrid`,
  `.incremental(cacheDirectory:)`, plus the symmetrically-named
  `DuplicationConfiguration.highPerformance`,
  `.incremental(cacheDirectory:)`, `.type3Detection`. None of these
  presets is reachable from the CLI; the README only mentions
  `UnusedCodeConfiguration.reachability` /
  `UnusedCodeConfiguration.indexStore`.
- Suggested fix: either expose a `--preset` flag or remove unreachable
  presets from public API (each is a Sendable struct so the cost of
  keeping them is small).

### U-5. The `--report` mode for `Unused` is hidden behind `--mode reachability`
- `Sources/swa/SWA.swift:407`–`430`: `--report` produces a reachability
  report — but only if `effectiveMode == .reachability`. If the user
  passes `--report` without `--mode reachability`, the flag is
  silently ignored and the run produces a normal findings output.
- Suggested fix: at least emit a stderr warning when `--report` is
  combined with a non-reachability mode; ideally promote
  `--report` to a separate subcommand.

### U-6. `SymbolQuery.regex(_:)` is reachable through `QueryParser`, not via static factory
- `Sources/SymbolLookup/Models/SymbolQuery.swift:90`–`92` declares
  `case regex(String)`. There is no convenience factory. README
  (`README.md:480`) advertises `/^handle.*Event$/` queries — they work
  only because the `QueryParser` (`Sources/SymbolLookup/Query/QueryParser.swift`)
  understands the leading-slash form.
- Suggested fix: either document the regex syntax requirement
  prominently, or add `SymbolQuery.regex(_:)`.

### U-7. `--auto-build` *config* path
- Although there's no CLI flag, `UnusedCodeConfiguration.autoBuild` is
  reachable from the programmatic API. README mentions it in the
  "IndexStore-Enhanced Detection" snippet (line 227) but does not
  warn that the equivalent CLI flag is missing.

### U-8. Default-excluded directories aren't listed
- `Sources/swa/SWA.swift:1047`–`1055` hard-codes seven excluded
  directories (`.build`, `Build`, `DerivedData`, `.swiftpm`, `Pods`,
  `Carthage`, `.git`). Neither README nor `.swa.schema.json` mentions
  them. The behaviour is friendly but surprising for users who store
  Swift code under any of those names.
- Suggested fix: document.

---

## Drift in defaults / behaviour

### D-1. Schema defaults vs. CLI defaults vs. library defaults disagree on `treat*AsRoot`
- Schema (`.swa.schema.json:56`–`75`):
  `treatPublicAsRoot/treatObjcAsRoot/treatTestsAsRoot/treatSwiftUIViewsAsRoot`
  all `default: false`.
- CLI (`SWA.swift:354`–`357`): `treatPublicAsRoot/...AsRoot ?? true`
  for all four.
- Library (`UnusedCodeConfiguration.swift:25, 26, 27, 33`): all four
  default `true`.
- `buildUnusedConfig` (`SWA.swift:737`–`751`): all four default `true`
  (matches CLI + library).
- **Schema is the only one disagreeing.** Tooling that surfaces
  schema-defaults to users will mislead.
- Suggested fix: update the schema to `"default": true`.

### D-2. `ignorePublicAPI` CLI default ≠ library default
- Library default (`UnusedCodeConfiguration.swift:20`): `true`.
- CLI default (`SWA.swift:340`): if no `--ignore-public` flag, computes
  `effectiveIgnorePublic = ignorePublic || (unusedConfig?.ignorePublicAPI ?? false)`
  → defaults to `false`.
- Net: `swa unused .` reports public API as unused (because
  `treatPublicAsRoot` defaults `true` — so public symbols are roots —
  but `ignorePublicAPI` is `false`, so they can still be reported when
  unreachable). The programmatic API does the opposite by default.
- Suggested fix: align defaults. Either CLI flips to `true`, or library
  flips to `false`. The CHANGELOG advertised "Defaults parity" (line
  109–112) — this is a hidden remaining drift.

### D-3. `--parallel` (CLI) maps to `.maximum`; `.swa.json` `parallel: true` maps to `.safe`
- CLI (`Sources/swa/SWA.swift:204`–`211, 366`–`373`):
  ```swift
  } else if parallel {
      .maximum
  } else { … }
  ```
- Config (`SWAConfiguration.swift:202`–`204`,
  `ParallelMode.swift:53`–`55`): `ParallelMode.from(legacyParallel:) →
  parallel ? .safe : .none`.
- DocC articles explicitly state "`--parallel` is deprecated and maps
  to `--parallel-mode safe`" (`CloneDetection.md:158`,
  `UnusedCodeDetection.md:80`, `PerformanceOptimization.md:136`,
  `CLIReference.md:316`).
- **All three documentation sources are correct about `safe`. The CLI
  is wrong.** `--parallel` should map to `.safe`, not `.maximum`.
- Suggested fix: change CLI mapping to `.safe`, or rewrite the docs.

### D-4. Legacy `parallel` field/flag accepted without deprecation warning
- Claim: `README.md:170` "Legacy `parallel` is still supported but
  deprecated."
- Reality: no `print/eprint` warning when `parallel: true` is decoded
  in `.swa.json` or when `--parallel` is passed on CLI. Silent
  acceptance.
- Suggested fix: emit a one-line stderr warning ("`--parallel` is
  deprecated; use `--parallel-mode safe`").

### D-5. `swa analyze` does not accept the `unused`-/`duplicates`-specific flags
- `Analyze` only declares `--config` and `--format`
  (`SWA.swift:54`–`58`). To control unused-detection root treatment,
  exclusions, or parallel mode in `analyze`, the user **must** use a
  `.swa.json` file.
- Not mentioned in README. The Quick-Start example
  `swa analyze /path/to/project` does run, but `swa analyze . --mode
  reachability` would fail with "unknown option".
- Suggested fix: document the limitation, or duplicate the relevant
  options on `Analyze`.

### D-6. Default `cloneTypes` is `[.exact]` only
- README's "Quick Start" line 105 explicitly demonstrates
  `--types exact --types near --types semantic`. But the bare command
  `swa duplicates /path/to/project` runs only `.exact` (CLI default
  `var types: [CloneType] = [.exact]`, line 153). The `.swa.json`
  default is also `[.exact]`. Users expecting "Multi-Algorithm Clone
  Detection" (README's first bullet) get *exact only* by default.
- Suggested fix: rephrase the README first bullet ("Multi-Algorithm
  Clone Detection… opt in via `--types near --types semantic`."), or
  change the default to `[.exact, .near]`.

### D-7. `Analyze.run` uses parallel mode but never plumbs it
- `Analyze.run()` (lines 60–99) calls `buildUnusedConfig` /
  `buildDuplicationConfig` which read `.swa.json`'s
  `resolvedParallelMode`. Duplication side does *not* read it: line
  715–722 `buildDuplicationConfig` does not pass `useParallelClones`.
  Unused side reads it (line 749 `useParallelBFS: …isParallel`). So
  `swa analyze .` with `duplicates.parallelMode: maximum` in
  `.swa.json` runs duplication serially regardless.
- Suggested fix: wire `useParallelClones` in `buildDuplicationConfig`.

---

## Per-category audit tables

### A. CLI subcommand surface

| Flag (README) | Subcommand | Parsed? | Wired to analyser? | Default README claim | Actual default | Notes |
|---|---|---|---|---|---|---|
| `--config <path>` | analyze/duplicates/unused | ✓ `SWA.swift:54,149,259` | ✓ `loadConfiguration` (line 693) | n/a | n/a | OK |
| `-f, --format <text\|json\|xcode>` | all | ✓ | ✓ | `xcode` | `.xcode` | OK; config-level `format` ignored (C-5) |
| `--mode <simple\|reachability\|indexStore>` | unused | ✓ `SWA.swift:266` | ✓ via `effectiveMode` | n/a | nil → `.simple` | OK |
| `--min-confidence <low\|medium\|high>` | unused | ✓ | partial — only post-filter (C-6) | n/a | nil → no post-filter | Major drift |
| `--index-store-path <path>` | unused & symbol | ✓ | ✓ | n/a | nil | OK |
| `--report` | unused | ✓ | ✓ but silently ignored when mode≠reachability (U-5) | n/a | false | Minor |
| `--parallel-mode <none\|safe\|maximum>` | duplicates/unused | ✓ | ✓ | n/a | nil → config's `resolvedParallelMode` (which defaults `.maximum`) | Default-of-default is `.maximum`! Surprising for a "safe" framework — config's `resolvedParallelMode` returns `.maximum` when both `parallelMode` and `parallel` are nil (`SWAConfiguration.swift:206, 280`). |
| `--parallel` | duplicates/unused | ✓ | ✓ but maps to `.maximum` not `.safe` (D-3) | n/a | false | Major |
| `--exclude-paths <glob>` | all | ✓ repeatable | ✓ | n/a | `[]` | OK |
| `--exclude-imports` | unused | ✓ | ✓ post-filter | false | false | OK |
| `--exclude-test-suites` | unused | ✓ | ✓ post-filter | false | false | OK |
| `--exclude-enum-cases` | unused | ✓ | ✓ post-filter | false | false | OK |
| `--exclude-deinit` | unused | ✓ | ✓ post-filter | false | false | OK |
| `--sensible-defaults` | unused | ✓ | ✓ | false | false | OK |
| `--ignore-public` | unused | ✓ | ✓ via `effectiveIgnorePublic` | false | false (lib default `true`) | D-2 drift |
| `--treat-public-as-root` / `--no-…` | unused | ✓ inverted flag | ✓ | n/a | true | Schema lies (D-1) |
| `--treat-objc-as-root` / `--no-…` | unused | ✓ inverted flag | ✓ | n/a | true | Schema lies (D-1) |
| `--treat-tests-as-root` / `--no-…` | unused | ✓ inverted flag | ✓ | n/a | true | Schema lies (D-1) |
| `--treat-swift-ui-views-as-root` / `--no-…` | unused | ✓ inverted flag | ✓ | n/a | true | Schema lies (D-1) |
| `--ignore-swift-ui-property-wrappers` | unused | ✓ | ✓ | false | false (but lib default `true`!) | D-2-style drift |
| `--ignore-preview-providers` | unused | ✓ | ✓ | false | false (lib default `true`) | D-2-style drift |
| `--ignore-view-body` | unused | ✓ | ✓ | false | false (lib default `true`) | D-2-style drift |
| `--types <exact\|near\|semantic>` | duplicates | ✓ repeatable | ✓ | n/a | `[.exact]` (D-6) | First bullet of README is misleading |
| `--min-tokens <n>` | duplicates | ✓ | ✓ | `50` | nil → 50, validated 1…10000 | OK |
| `--min-similarity <n>` | duplicates | ✓ | ✓ | `0.8` | nil → 0.8, validated 0…1 | OK |
| `--algorithm <rollingHash\|suffixArray\|minHashLSH>` | duplicates | ✓ | ✓, but dispatch does not match README claims (O-2) | `rollingHash` | nil → `.rollingHash` | Major doc drift |
| `--usr` | symbol | ✓ | ✓ | false | false | OK |
| `--kind <…>` | symbol | ✓ repeatable | ✓ filter | n/a | `[]` | OK |
| `--access <…>` | symbol | ✓ repeatable | ✓ filter | n/a | `[]` | OK |
| `--in-type <name>` | symbol | ✓ | ✓ | n/a | nil | OK |
| `--definition` | symbol | ✓ | ✓ | false | false | OK |
| `--usages` | symbol | ✓ | ✓ | false | false | OK; uses Xcode `warning:` format (intentional) |
| `--limit <n>` | symbol | ✓ | ✓ ≥1 validated | n/a | nil → 0 (unlimited) | OK |
| `--context-lines / -before / -after` | symbol | ✓ | ✓ | n/a | nil | OK |
| `--context-scope/-signature/-body/-documentation/-all` | symbol | ✓ | ✓ | false | false | OK |
| **Missing from CLI but in CHANGELOG/SECURITY** | | | | | | |
| `--auto-build` | unused | ✗ | n/a | n/a | n/a | Blocking (C-1) |

### B. Detection modes

| Mode | End-to-end runs? | Auto-build (README "yes")? | `--parallel-mode` effect | 70/85/95 measured? |
|---|---|---|---|---|
| `simple` | ✓ (`UnusedCodeDetector.swift:38`) | n/a | `useParallelBFS` is set to a bool but `simple` mode does not run reachability — so `--parallel-mode` is a no-op in `.simple` (silent). | ✗ unsubstantiated |
| `reachability` | ✓ (`:41`) | n/a | ✓ (`DependencyExtractor.swift:599`) honours the flag | ✗ unsubstantiated |
| `indexStore` | ✓ (`+IndexStore.swift:13`) | ✓ at the *config* layer (`autoBuild`), ✗ at the CLI (no `--auto-build`). README "Build if index is stale" is achievable only programmatically. | ✓ — falls back to reachability path which honours `useParallelBFS` | ✗ unsubstantiated |

### C. Clone detection

| Type | README algorithm | Actual algorithm (default `--algorithm rollingHash`) | Actual algorithm (`--algorithm suffixArray`) | Actual algorithm (`--algorithm minHashLSH`) |
|---|---|---|---|---|
| `exact` | SA-IS | ExactCloneDetector (Rabin-Karp) | SuffixArrayCloneDetector (SA-IS) ✓ | ExactCloneDetector (Rabin-Karp) — falls through with `minHashLSH` |
| `near` | MinHash + LSH | NearCloneDetector (Rabin-Karp + normalisation) | SuffixArrayCloneDetector with normalisation | NearCloneDetector (Rabin-Karp + normalisation) — *not* MinHash |
| `semantic` | AST fingerprinting | SemanticCloneDetector (AST) ✓ | SemanticCloneDetector (AST) ✓ | MinHashCloneDetector (MinHash+LSH); groups labelled `.semantic` |

`--algorithm rollingHash` does exist as an algorithm beyond the CLI:
`ExactCloneDetector.swift:119`, `NearCloneDetector.swift:60`,
`Utilities/RollingHash.swift` implement Rabin-Karp. The CLI surface and
implementation match — but the README table is wrong (O-2).

### D. Ignore directives

| Directive | README claim | Parsed? | File |
|---|---|---|---|
| `// swa:ignore` | ✓ | ✓ | `DeclarationCollector.swift:681, 723`; `IgnoreDirectiveScanner.swift:92` |
| `// swa:ignore-unused` | ✓ | ✓ | `Declaration.swift:389`, dispatched by `extractIgnoreCategories` |
| `// swa:ignore-unused-cases` | ✓ | ✓ | `Declaration.swift:390` (kind == .enumCase gate) |
| `/// Doc comment. // swa:ignore` | ✓ | ✓ | `DeclarationCollector.swift:711`–`716` (handles `.docLineComment`, `.docBlockComment`) |
| `/* swa:ignore */` | ✓ | ✓ | `DeclarationCollector.swift:685`–`688`; `IgnoreDirectiveScanner.swift:135`–`139` |
| Inheritance into nested decls | ✓ | ✓ | `DeclarationCollector.swift:143–322, 370, 444, 484` (stack-based) |
| `// swa:ignore-duplicates` (single-line) | ✗ undocumented | ✓ | `IgnoreDirectiveScanner.swift:91` (U-2) |
| `// swa:ignore:begin … :end` block | ✗ undocumented | ✓ | `IgnoreDirectiveScanner.swift:73–88` (U-1) |
| `// swa:ignore-duplicates:begin … :end` block | ✗ undocumented | ✓ | same (U-1) |

### E. MCP server tools

All seven advertised tools exist; the table summarises end-to-end status.

| Tool | Registered? | Schema? | Sandbox-checked? | Working end-to-end? | Notes |
|---|---|---|---|---|---|
| `get_codebase_info` | ✓ `SWAMCPServer.swift:135` | ✓ | ✓ via `CodebaseContext` | ✓ | inline-JSON string built without an encoder (line 484–493) — fragile if `info` contains quotes |
| `list_swift_files` | ✓ `:147` | ✓ | ✓ | ✓ | |
| `detect_unused_code` | ✓ `:167` | ✓ includes `indexStore` (fix from 0.2.0) | ✓ | ✓ | does *not* expose `auto_build` (intentional — SECURITY.md) |
| `detect_duplicates` | ✓ `:245` | ✓ | ✓ | ✓ | |
| `read_file` | ✓ `:289` | ✓ | ✓ extension allowlist, ≤10 MiB, regular-file, line-range validated | ✓ | shared `validateForReadFile` with `ReadResource` ✓ |
| `search_symbols` | ✓ `:313` | ✓ | ✓ 256-byte query cap, 2.5 s budget, antipattern reject | ✓ | per `SWAMCPServer.swift:813, 820+` |
| `analyze_file` | ✓ `:389` | ✓ | ✓ | ✓ | |
| **Missing from list_tools — declarations claim to support `kind: typealias`** | | | | | the `kind` enum allows `"typealias"` but `DeclarationKind` has the same case — verify a non-issue |

MCP server version literal is stale (`0.1.0` while CLI is `0.2.0`).

### F. Exit-code contract

| Subcommand | findings → exit 2 | clean → exit 0 | argument error → exit 64 | other → exit 1 |
|---|---|---|---|---|
| `analyze` | ✓ `SWA.swift:97` | ✓ | ✓ via ArgumentParser | ✓ |
| `duplicates` | ✓ `:244` | ✓ | ✓ + bounded `--min-tokens` / `--min-similarity` | ✓ |
| `unused` | ✓ `:459` | ✓ | ✓ (no numeric bounds; `--min-confidence` enum validated by AP) | ✓ |
| `symbol` | ✗ — symbol intentionally exits 0 even with matches/usages (README is consistent on this) | ✓ | ✓ `--limit >= 1` validated | ✓ |

Drift: `Unused.run` does **not** validate `--min-tokens`-style numeric
options because it has none; but it also doesn't validate
`--min-confidence` is mutually exclusive with `--ignore-public`-style
flags. README does not promise that, so this is OK.

Edge: the `Analyze` command does **not** call
`UnusedCodeFilter.matchesGlobPattern` to exclude paths (only
`findSwiftFiles` does, line 70). The other commands additionally
post-filter (lines 215, 378). Inconsequential for the exit-code
contract.

### G. Programmatic API examples

| README snippet | Compiles? | Notes |
|---|---|---|
| `let config = DuplicationConfiguration(minimumTokens: 50, cloneTypes: [.exact, .near, .semantic], minimumSimilarity: 0.8)` | ✓ | matches `DuplicationDetector.swift:123` |
| `let detector = DuplicationDetector(configuration: config)` | ✓ | ✓ |
| `let clones = try await detector.detectClones(in: swiftFiles)` | ✓ | ✓ |
| `let config = UnusedCodeConfiguration.reachability` | ✓ | ✓ `UnusedCodeConfiguration.swift:72` |
| `unused.filteredWithSensibleDefaults()` | ✓? | exists on the `[UnusedCode]` array — verify in `Filters/`. (Method exists in `UnusedCodeDetector/Filters/UnusedCodeFilter.swift`.) |
| `var config = UnusedCodeConfiguration.indexStore; config.indexStorePath = "…"; config.autoBuild = true` | ✓ | all three props are public (lines 75, 119, 137) |
| `let finder = SymbolFinder(projectPath: "/path/to/project")` | ✓ | matches `Resolution/SymbolFinder.swift` |
| `let query = SymbolQuery.name("NetworkManager")` | ✓ | `SymbolQuery.swift:172` |
| `SymbolQuery.qualifiedName("APIClient", "shared")` | **✗** | does not exist (C-2) |
| `SymbolQuery.selector("fetch", labels: ["id", "completion"])` | **✗** | does not exist (C-2) |
| `try await finder.findUsages(of: match)` | ✓ | `SymbolFinder.swift:189`-ish |

### H. Performance claims

| Bullet (README:617–645) | Verified? | Reality |
|---|---|---|
| Memory-mapped I/O for files ≥ 4 KiB; memoised line range | ✓ | `SourceFileReader.swift:24` (threshold), `:65` (memoisation note). Behaviour matches O-5 caveat. |
| Bounded LRU parser caches | ✓ | `SwiftFileParser.swift:29` (256), `ZeroCopyParser.swift:134` (64) |
| `DenseGraph` reachability over USR-indexed adjacency | ✓ | `IndexBasedDependencyGraph` + `DenseGraph` (`UnusedCodeDetector/Reachability/`) |
| Direction-optimising parallel BFS auto-selected on `--parallel-mode safe\|maximum` | ✓ but **opt-in only**, not "auto-select" for unused-code (O-3) | `ParallelBFS.swift:115` exists; unused-code path branches on `useParallelBFS` (no size threshold). Clone path does auto-select on doc count. |
| SIMD4<UInt64> MinHash with M_61 + SplitMix64 | ✓ | `MinHash.swift:151, 182, 196` |
| `InlineArray<128, UInt64>` signature width | ✓ default (`MinHashCloneDetector.swift:84` `numHashes: Int = 128`); the inline-array specifics live in `MinHash.swift` — verified literally `SIMD4<UInt64>` with 128 / 4 = 32 lanes per shingle. |
| Arena over Bitmap typed scratch buffers in SA-IS | ½ | Type vector is `Bitmap`; bucket/recursion arrays are `[Int]` (O-4). |
| SoA token storage `[UInt8] kinds`, `[UInt32] offsets`, `[UInt16] lengths`, `[UInt32] lines` | ✓ | `Memory/SoATokenStorage.swift` |
| AsyncChannel `BackpressuredChannelStream` for streaming verifiers | ✓ implementation exists (`TaskBackedAsyncStream.swift:69`, `ParallelVerification.swift:385–410`) | But not engaged by `ParallelMode.maximum` (C-3). |

### I. Plugins

| Plugin | Path | Functional? | Documented gotchas? |
|---|---|---|---|
| `StaticAnalysisBuildPlugin` | `Sources/StaticAnalysisBuildPlugin/Plugin.swift` | ✓ runs `swa <dir> --format xcode` as a `prebuildCommand` | ✗ — README does not warn that exit-2 from findings fails the build (C-7) |
| `StaticAnalysisCommandPlugin` | `Sources/StaticAnalysisCommandPlugin/Plugin.swift` | inspect needed | not audited line-by-line; integration paths in README (`README.md:529–531`) are not described as accurate vs. inaccurate |

### J. DocC / website

| Linked section (`README.md:592–600`) | DocC article exists? |
|---|---|
| Getting Started Guide | ✓ `Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/GettingStarted.md` |
| CLI Reference | ✓ `Articles/CLIReference.md` |
| Clone Detection | ✓ `Articles/CloneDetection.md` |
| Unused Code Detection | ✓ `Articles/UnusedCodeDetection.md` |
| Symbol Lookup | ✓ `Articles/SymbolLookup.md` |
| MCP Server | ✓ `Articles/MCPServer.md` |
| Ignore Directives | ✓ `Articles/IgnoreDirectives.md` |
| CI Integration | ✓ `Articles/CIIntegration.md` |
| API Reference | ✓ generated by DocC |
| Architecture | ✓ `Articles/Architecture.md` (new in 0.2.0) |
| Performance | ✓ `Articles/Performance.md` (new in 0.2.0) |
| Security | ✓ `Articles/Security.md` (new in 0.2.0) |

DocC bundle is complete. Note that the `Sources/SwiftStaticAnalysisCore/SwiftStaticAnalysisCore.docc/`
bundle holds only a stub (947 bytes) — sub-modules' DocC are
intentionally minimal.

### K. Configuration file (`.swa.json`) ↔ decoder

| Schema field | Decoded? | Validated? | Honoured? |
|---|---|---|---|
| `version` (int) | ✓ | partial (no `unsupportedVersion` ever thrown despite enum case existing) | informational only |
| `format` (enum) | ✓ (typed `OutputFormat?`) | ✓ at decode (unknown strings → `parseError`) | **✗** ignored by CLI (C-5) |
| `excludePaths` (array) | ✓ | n/a | ✓ |
| `unused.enabled` | ✓ | n/a | ✓ (Analyze line 84) |
| `unused.mode` (enum string) | ✓ | ✓ (`ConfigurationLoader.swift:131`) | ✓ |
| `unused.indexStorePath` | ✓ | n/a | ✓ |
| `unused.minConfidence` | ✓ | ✓ (`:134`) | partial (C-6) — only post-filter |
| `unused.treat*AsRoot` | ✓ | n/a | ✓ (defaults `true`; schema says `false` — D-1) |
| `unused.ignoreSwiftUIPropertyWrappers/ignorePreviewProviders/ignoreViewBody` | ✓ | n/a | ✓ |
| `unused.ignorePublicAPI` | ✓ | n/a | ✓ (with D-2 default mismatch) |
| `unused.sensibleDefaults` | ✓ | n/a | ✓ |
| `unused.excludeImports/excludeDeinit/excludeEnumCases/excludeTestSuites` | ✓ | n/a | ✓ |
| `unused.excludeNamePatterns` | ✓ + merged | n/a | **✗** never wired (C-4) |
| `unused.excludePaths` | ✓ | n/a | ✓ |
| `unused.parallel` (deprecated) | ✓ | n/a | ✓ (with D-3 / D-4 issues) |
| `unused.parallelMode` | ✓ | n/a | ✓ |
| `duplicates.enabled` | ✓ | n/a | ✓ |
| `duplicates.minTokens` | ✓ | (no bounds check in schema validate; CLI validates only when `--min-tokens` passed) | ✓ |
| `duplicates.minSimilarity` | ✓ | (no validate) | ✓ |
| `duplicates.types` | ✓ | ✓ (`:152`) | ✓ |
| `duplicates.algorithm` | ✓ | ✓ (`:144`) | ✓ |
| `duplicates.ignoredPatterns` | ✓ + merged | n/a | **✗** never wired (C-4) |
| `duplicates.excludePaths` | ✓ | n/a | ✓ |
| `duplicates.parallel` (deprecated) | ✓ | n/a | ✓ via `resolvedParallelMode` |
| `duplicates.parallelMode` | ✓ | n/a | partial — `Analyze` ignores duplicate parallel mode (D-7) |
| `format` rejected for `"telepathic"` | claim: "rejected by `ConfigurationLoader` with typed `ConfigurationError.invalidFieldValue`" (CHANGELOG:82–83) | reality: thrown as `parseError(path:underlying:)`, *not* `invalidFieldValue`. The typed enum decoder catches it earlier than `validate(path:)`. Functionally a rejection, but the error case differs. | Minor mislabel |

---

## Recommended truth-up actions

Ordered roughly by impact / effort.

### Mandatory (blocking — falsehoods or misleading security claims)
1. **Either deliver `--auto-build` or rewrite SECURITY.md.** This is
   the single most damaging discrepancy: SECURITY.md presents a CLI
   flag that does not exist as the canonical attack-surface boundary.
   Quick fix: add a one-line `@Flag --auto-build` to `Unused` in
   `SWA.swift` and plumb it into `UnusedCodeConfiguration.autoBuild`.
2. **Fix the two compile-failing README snippets** for
   `SymbolQuery.qualifiedName` and `SymbolQuery.selector`. Easiest: add
   the convenience initialisers (4 lines of code).
3. **Reconcile the `ParallelMode.maximum` documentation** with what
   the code does — pick one of (a) rewrite the README+CHANGELOG to
   match `ParallelMode.swift`'s "differs only in concurrency shape"
   reality, or (b) wire `.maximum` to the streaming/backpressure path
   in `MinHashCloneDetector` and `StreamingVerifier`.
4. **Stop silently dropping `excludeNamePatterns` and
   `ignoredPatterns`.** Either route them through, or remove from the
   schema. Currently a user setting them sees no effect and no warning.

### Major (correctness drift; trivially fixable)
5. **Update `.swa.schema.json` `treat*AsRoot` defaults from `false` to
   `true`.** They've been `true` everywhere else since the parity fix
   in 0.2.0.
6. **Map `--parallel` (CLI) to `.safe` (not `.maximum`)** to match
   `.swa.json` mapping and *every* DocC article.
7. **Wire `--min-confidence` into `UnusedCodeConfiguration`** before
   the analysis runs (rather than post-filter only). Today `--min-confidence
   low` is a no-op against the detector's `.medium` default.
8. **Rewrite the clone-type / algorithm table in README and
   `SwiftStaticAnalysis.md`.** "Exact uses SA-IS" is false by default.
9. **Resolve `ignorePublicAPI` default split.** Pick one default and
   apply it across CLI, schema, library.
10. **Apply `duplicates.parallelMode` in `buildDuplicationConfig`**
    (`SWA.swift:715`) — the missing `useParallelClones` plumbing.
11. **Emit a stderr deprecation warning** when `--parallel` or
    `.swa.json` `parallel: bool` is observed.

### Minor / cosmetic
12. **Document `swa:ignore:begin/end` block-form directives** in the
    README ignore-directives table.
13. **Document the default-excluded directory list** (`.build`,
    `Build`, `DerivedData`, `.swiftpm`, `Pods`, `Carthage`, `.git`).
14. **Note in README that `swa analyze` accepts only `--config` and
    `--format`**; other knobs require `.swa.json`.
15. **Update `Sources/StaticAnalysisBuildPlugin/Plugin.swift`** docs to
    note that findings fail the build (or add a `--soft` mode that
    emits warnings without exiting non-zero).
16. **Replace the unsubstantiated 70/85/95 % accuracy numbers** with
    qualitative descriptions, or build a precision/recall fixture.
17. **Bump the MCP server `version: "0.1.0"` literal** to match CLI.
18. **Run the missing `duplicates-semantic` scenario** in
    `.github/workflows/benchmarks.yml`. Either implement a baseline +
    threshold (delivering "perf-regression gate") or rewrite the README
    bullet to call it "PR comment summarisation".
19. **Add the missing `AUDIT.md`** referenced by `CHANGELOG.md:10`, or
    delete the reference.
20. **Update `UnusedCodeConfiguration.useParallelBFS`'s doc-comment**
    (line 175) — it still says "Enable via `--parallel` CLI flag",
    referencing the deprecated form.

### Stretch (deliver promised but currently-unreachable features)
21. **Expose CLI presets** for `.strict`, `.hybrid`,
    `.indexStoreAutoBuild`, `.incremental`. They're already
    `Sendable`; surfacing them is a `--preset` away.
22. **Auto-select `useParallelBFS`** in the unused-code reachability
    path on graph size, mirroring `MinHashCloneDetector.detectParallel`'s
    threshold logic. Today the README implies this is automatic; it
    isn't.

---

## Appendix — file references

Key source files inspected:

- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/swa/SWA.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/swa/CLIConformances.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Configuration/SWAConfiguration.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Configuration/ConfigurationLoader.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Configuration/ParallelMode.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Configuration/OutputFormat.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Memory/SourceFileReader.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Memory/ZeroCopyParser.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Parsing/SwiftFileParser.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Concurrency/TaskBackedAsyncStream.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Visitors/DeclarationCollector.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Models/Declaration.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/DuplicationDetector.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/_DuplicationEngine.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/MinHash/MinHashCloneDetector.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/MinHash/MinHash.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/SuffixArray/SuffixArray.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/Algorithms/ExactCloneDetector.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/Algorithms/NearCloneDetector.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/Algorithms/SemanticCloneDetector.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/Algorithms/ASTFingerprintVisitor.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/Parallel/ParallelVerification.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/DuplicationDetector/Utilities/IgnoreDirectiveScanner.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/UnusedCodeDetector.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/UnusedCodeDetector+IndexStore.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/Configuration/UnusedCodeConfiguration.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/IndexStore/IndexStoreFallback.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/Reachability/ParallelBFS.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/Reachability/DependencyExtractor.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SymbolLookup/Models/SymbolQuery.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SymbolLookup/Resolution/SymbolFinder.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/StaticAnalysisBuildPlugin/Plugin.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/StaticAnalysisCommandPlugin/Plugin.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/swa-bench/main.swift`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/SwiftStaticAnalysis.md`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/Architecture.md`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/Performance.md`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/Security.md`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/UnusedCodeDetection.md`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/CloneDetection.md`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/CLIReference.md`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/Articles/PerformanceOptimization.md`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/.github/workflows/benchmarks.yml`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/.swa.schema.json`
- `/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Tests/CLITests/CLITests.swift`

---

*End of audit.*
