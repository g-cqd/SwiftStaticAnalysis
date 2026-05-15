# Architecture Audit — SwiftStaticAnalysis 0.2.0

Audit date: 2026-05-15  
Auditor: automated architecture review  
Codebase: ~35 K LOC, 116 Swift source files, swift-tools-version 6.2  

---

## Summary

SwiftStaticAnalysis 0.2.0 is architecturally mature for a project of its age. The module graph is largely clean, the prior reverse-dependency cycle (DuplicationDetector → UnusedCodeDetector via Bitmap) was correctly resolved, and the security hardening done in sweeps 1–2 is thorough. What remains are three structural smells worth fixing before a 1.0 claim: (1) `SymbolLookup` takes a hard dependency on `UnusedCodeDetector` purely to borrow `IndexStoreReader`, a type that belongs in `SwiftStaticAnalysisCore` or a dedicated `IndexStoreSupport` layer; (2) the public API surface of the CFG/dataflow subsystem (`VariableID`, `BlockID`, `BasicBlock`, `ControlFlowGraph`, `CFGBuilder`) is fully `public` despite having zero external callers, producing an unintentional and fragile ABI commitment; and (3) two incompatible glob-matching implementations coexist in `UnusedCodeDetector.Filters` and `SwiftStaticAnalysisMCP.CodebaseContext` with different match semantics (`contains` vs `wholeMatch`), which silently produces different exclusion results depending on which code path reaches them. The CI pipeline is mostly sound but has two documentation contradictions (`--parallel` maps to `.maximum` in code, `.safe` in the README), a stale MCP server version string (0.1.0 hardcoded inside a 0.2.0 release), a missing `duplicates-semantic` scenario in the benchmark workflow, and a self-analysis gate that will correctly block on findings now that exit code 2 is properly wired — which may surprise contributors who expect those steps to be advisory only.

---

## Findings

---

### F-01

**Severity:** High  
**Title:** `SymbolLookup` takes a compile-time dependency on `UnusedCodeDetector` to borrow `IndexStoreReader`  
**File:** `Package.swift:163-174`, `Sources/SymbolLookup/Resolution/IndexStoreResolver.swift:7`, `Sources/SymbolLookup/Resolution/SymbolFinder.swift:8`

**What:**  
`SymbolLookup` declares `UnusedCodeDetector` in its `dependencies` array and imports it in two files. The only types actually used from that import are `IndexStoreReader` (defined in `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift:221`) and, transitively, `IndexStoreDB`. `SymbolLookup` does not use any unused-code-detection logic.

**Why:**  
This creates an architectural layering violation: a feature module (`SymbolLookup`) depends on a sibling feature module (`UnusedCodeDetector`) to share infrastructure that is not semantically owned by that module. It means that any consumer who imports `SymbolLookup` (e.g., via the `SwiftStaticAnalysis` umbrella) also transitively compiles `UnusedCodeDetector` and pulls in the entirety of `IndexStoreDB`. The dependency direction is inverted from what the names imply.

**Recommendation:**  
Move `IndexStoreReader` (and `IndexStoreFallbackManager`, `IndexStoreError`) from `Sources/UnusedCodeDetector/IndexStore/` to `Sources/SwiftStaticAnalysisCore/IndexStore/` or into a new internal target `IndexStoreSupport`. Both `UnusedCodeDetector` and `SymbolLookup` would then depend on `SwiftStaticAnalysisCore`, which is the declared base layer. This is a non-breaking change at the `@_exported` umbrella level.

---

### F-02

**Severity:** High  
**Title:** Two glob-matching implementations with incompatible match semantics  
**File:** `Sources/UnusedCodeDetector/Filters/UnusedCodeFilter.swift:114-128`, `Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift:153-181`

**What:**  
There are two independent `matchesGlobPattern` functions. `UnusedCodeFilter.matchesGlobPattern` compiles the glob to an unanchored regex and calls `path.contains(regex)` — a partial match. `CodebaseContext.matchesGlobPattern` produces an anchored `^...$` regex and calls `path.wholeMatch(of:)` — a full match. Furthermore, within `SWAMCPServer`, `handleDetectUnusedCode` and `handleDetectDuplicates` call `UnusedCodeFilter.matchesGlobPattern` (partial) to post-filter files, while `CodebaseContext.findSwiftFiles` uses the `CodebaseContext` version (full). So in a single MCP tool call, the same glob pattern is evaluated with different semantics at the collection stage vs the filtering stage.

**Why:**  
A pattern like `Tests` (no wildcards) would match `/any/path/with/Tests/anywhere` under `contains` but nothing under `wholeMatch`. This silent inconsistency means that the same `.swa.json` `excludePaths` entry can produce different results depending on whether it runs through the CLI, the MCP tool, or the programmatic API.

**Recommendation:**  
Consolidate into a single canonical implementation in `SwiftStaticAnalysisCore/Utilities/` (e.g., `GlobMatcher`). The semantics should be wholeMatch with anchors, which matches user intent for glob patterns. Remove `CodebaseContext.matchesGlobPattern` and the `UnusedCodeFilter.globToRegexPattern` private method; replace all call sites with the canonical function.

---

### F-03

**Severity:** High  
**Title:** CFG/dataflow types fully public despite being internal infrastructure  
**File:** `Sources/UnusedCodeDetector/DataFlow/CFGBuilder.swift:27,68,88,121,153,209,300`

**What:**  
`VariableID`, `BlockID`, `CFGStatement`, `Terminator`, `BasicBlock`, `ControlFlowGraph`, and `CFGBuilder` are all declared `public`. The CFG subsystem is used only by `LiveVariableAnalysis` and `ReachingDefinitions` within `UnusedCodeDetector`. There are no callers outside the module. The `UnusedCodeDetector` product is exposed as a library product, so these types are part of its ABI.

**Why:**  
Making implementation details public creates an unintentional API commitment. If the internal CFG representation changes (e.g., merging `BasicBlock.use`/`def` into a single struct, or changing `BlockID` from `String`-backed to integer-backed for performance), it becomes a breaking change for any consumer who referenced these types. The 157 `public` declarations counted in the DataFlow directory create substantial surface with no external benefit.

**Recommendation:**  
Demote all CFG types to `internal` or, if cross-file access within the module is needed, `package`. The `// swa:ignore-unused-cases` comments on `Terminator` cases indicate the tooling already notices the problem — the fix is access restriction, not suppression. If a future consumer genuinely needs CFG access, gate that behind an explicit new library product.

---

### F-04

**Severity:** Medium  
**Title:** `SwiftStaticAnalysisCore` publicly re-exports `SwiftSyntax` and `SwiftParser`  
**File:** `Sources/SwiftStaticAnalysisCore/SwiftStaticAnalysisCore.swift:7-8`

**What:**  
```swift
@_exported import SwiftParser
@_exported import SwiftSyntax
```
Any consumer who imports `SwiftStaticAnalysisCore` (directly or via the umbrella) silently gains access to the entire `SwiftSyntax` and `SwiftParser` public APIs without declaring that dependency in their own `Package.swift`.

**Why:**  
This violates the principle that `@_exported` is appropriate only when the re-exported module's types appear in the re-exporting module's own public API signatures. `SwiftSyntax` types do appear in `DeclarationCollector`, `ReferenceCollector`, and `SwiftFileParser` signatures, so there is a legitimate case — but the re-export also exposes hundreds of `SwiftSyntax` parse-tree types that are purely internal details. Consumers who rely on this incidentally will break when the project changes its `swift-syntax` version alignment, since `swift-syntax` follows a strict version-coupling contract.

**Recommendation:**  
Restrict the re-export to only the types that genuinely appear in public API signatures. For example, `SourceLocationConverter` is already covered by the explicit `typealias` on line 13. Consider whether `SyntaxVisitor` needs to be re-exported or if visitors should be opaque.

---

### F-05

**Severity:** Medium  
**Title:** `swa` CLI's `canonicalizePath` duplicates `PathUtilities.canonicalize` with different semantics  
**File:** `Sources/swa/SWA.swift:1059-1082`

**What:**  
`swa/SWA.swift` defines a local free function `canonicalizePath` that uses `URL.standardized` followed by `URL(resolvingAliasFileAt:options:.withoutMounting)`. `PathUtilities.canonicalize` (in `SwiftStaticAnalysisCore`) uses `URL.resolvingSymlinksInPath().standardizedFileURL`. These produce different results on macOS where `.app` bundles are Finder aliases, where `/var` symlinks to `/private/var`, and where HFS+ alias files exist.

**Why:**  
The MCP sandbox hardening (`CodebaseContext.validatePath`) correctly uses `PathUtilities.canonicalize`. The CLI uses a different resolution path. A maliciously crafted symlink that the CLI's `canonicalizePath` resolves one way and `PathUtilities.canonicalize` resolves differently could be used to bypass path restrictions if the CLI ever enforces a root boundary (it currently does not have a sandboxed root, but this is still a maintenance footgun). The divergence also makes it impossible to reason about whether two paths are identical across the system.

**Recommendation:**  
Delete `canonicalizePath` from `swa/SWA.swift` and replace all call sites with `PathUtilities.canonicalize`. The `swa` target already depends on `SwiftStaticAnalysisCore`, so no new dependency is needed.

---

### F-06

**Severity:** Medium  
**Title:** `swa` CLI `findSwiftFiles` does not filter symbolic links  
**File:** `Sources/swa/SWA.swift:1117-1148`

**What:**  
The CLI's file enumerator is created with `includingPropertiesForKeys: [.isRegularFileKey]` but does not request `.isSymbolicLinkKey` and does not re-canonicalize each discovered file URL to verify it stays within a sandbox root. The MCP `CodebaseContext.findSwiftFiles` explicitly resolves each file's canonical path and skips any whose canonical target points outside the root.

**Why:**  
The CLI does not enforce a sandbox root the way the MCP server does, so the omission is not a security boundary failure in the same sense. However, the CLI can follow symlinks into `.build/` artifact trees, external dependency checkouts referenced via symlinks, or Xcode SDKs if someone points it at a directory that uses symlinks as shortcuts. The existing `defaultExcludedDirectories` check operates on `pathComponents` of the potentially-symlinked path and would not catch a `Sources/real.swift -> /tmp/.build/some-artifact.swift` shortcut.

**Recommendation:**  
Add `.isSymbolicLinkKey` to `includingPropertiesForKeys` and skip files where `isSymbolicLink` is true, or re-resolve each URL with `resolvingSymlinksInPath()` and verify the result still has a sensible path structure. Align with `CodebaseContext.findSwiftFiles`.

---

### F-07

**Severity:** Medium  
**Title:** `--parallel` deprecated flag maps to `.maximum`, README claims it maps to `.safe`  
**File:** `Sources/swa/SWA.swift:207-208,369-370`, `README.md:170`

**What:**  
The README states: "`safe` matches legacy `--parallel`." The code maps `--parallel` to `.maximum`:
```swift
} else if parallel {
    .maximum
```
This is true in both `Duplicates.run()` (line 208) and `Unused.run()` (line 370).

**Why:**  
This is a documentation correctness failure. Users who read the README and use `--parallel` believing they are getting safe/conservative parallel behavior are actually getting `.maximum` (highThroughput preset). Conversely, `ParallelMode.from(legacyParallel:)` in `ParallelMode.swift:53` maps `true` to `.safe` — so the config-file path and the CLI flag path produce different results for the same intent.

**Recommendation:**  
Decide on one canonical mapping. The `ParallelMode.from(legacyParallel:)` static method correctly maps `true → .safe`; use that in the CLI too. Update the flag's handling to `ParallelMode.from(legacyParallel: parallel)` and delete the inline `else if parallel { .maximum }` branches.

---

### F-08

**Severity:** Medium  
**Title:** `SWAMCPServer` hardcodes `version: "0.1.0"` inside a 0.2.0 release  
**File:** `Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:49`

**What:**  
```swift
self.server = Server(
    name: "swa-mcp",
    version: "0.1.0",   // stale
    ...
)
```
The CLI (`swa/SWA.swift:31`) and `swa-mcp/main.swift:25` both declare `0.2.0`. The MCP server advertises itself to clients as `0.1.0`.

**Why:**  
MCP clients may use the server version for capability negotiation or user display. A stale version string misleads clients and is inconsistent with the product's release version.

**Recommendation:**  
Inject the version string through `SWAMCPServer.init` as a parameter (defaulting to a constant sourced from `swa-mcp/main.swift` or a shared `Version.swift` in `SwiftStaticAnalysisCore`). Alternatively, add a build-time script step that derives it from `Package.swift`. At minimum, bump the literal to match the release version on every release.

---

### F-09

**Severity:** Medium  
**Title:** `SymbolLookup` umbrella module is absent from the `SwiftStaticAnalysis` umbrella's package-level product list, but the README's SPM installation snippet says importing `SwiftStaticAnalysis` "gives you access to all components including the MCP server"  
**File:** `README.md:55`, `Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.swift`, `Package.swift:18-27`

**What:**  
The README on line 55 says: "This gives you access to all components including the MCP server." The `SwiftStaticAnalysis` product explicitly excludes `SwiftStaticAnalysisMCP` (that is intentional and documented elsewhere). However, the README statement is unqualified and appears directly beneath the `SwiftStaticAnalysis` SPM snippet, creating the impression that MCP is included.

Additionally, `SwiftStaticAnalysisOutput` is not exposed as a library product at all — it is a dependency of `swa` and `SwiftStaticAnalysisMCP` but cannot be imported by downstream consumers who might want its `CompactTextFormatter`.

**Why:**  
Inaccurate installation documentation causes consumers to discover the missing MCP dependency at link time, not at read time. The undiscoverable `SwiftStaticAnalysisOutput` forces any consumer who wants the compact formatter to either re-implement it or copy internal code.

**Recommendation:**  
Fix the README sentence to say "all analyzer components (not including the MCP server; use `SwiftStaticAnalysisAll` for that)." Add `SwiftStaticAnalysisOutput` as an explicit library product in `Package.swift` if external use is intended, or make it a `@_spi`-protected API.

---

### F-10

**Severity:** Medium  
**Title:** `SWAConfiguration.merging(with:)` is defined but never called  
**File:** `Sources/SwiftStaticAnalysisCore/Configuration/ConfigurationLoader.swift:192-261`

**What:**  
`SWAConfiguration` has a `merging(with:)` method (with full `mergeUnused` and `mergeDuplicates` helpers) that provides a principled CLI-overrides-config merge. The CLI in `swa/SWA.swift` performs its own ad-hoc merging inline (e.g., `minTokens ?? dupConfig?.minTokens ?? 50`) without calling `merging(with:)`.

**Why:**  
Dead code in the public API creates an ABI commitment with no benefit. Worse, it signals that there is a "correct" merging path that is not used, while the actual merging has no single place to inspect or test. The two paths can (and do) diverge — for example, `buildUnusedConfig` from `swa/SWA.swift` ignores `parallelMode` from the config file in the `swa analyze` path (though this was fixed in sweep 1), and similar drift could recur.

**Recommendation:**  
Either wire the CLI to actually call `SWAConfiguration.merging(with:)` and eliminate the inline merging, or remove `merging(with:)` from the public API and add a comment explaining the inline approach. If the former, the CLI must construct a `SWAConfiguration` from CLI flags and call `fileConfig.merging(with: cliConfig)`.

---

### F-11

**Severity:** Medium  
**Title:** `SwiftStaticAnalysisMCP` module re-exports `MCP` via `@_exported`  
**File:** `Sources/SwiftStaticAnalysisMCP/SwiftStaticAnalysisMCP.swift:41`

**What:**  
```swift
@_exported import MCP
```
Any consumer who imports `SwiftStaticAnalysisMCP` gets the full `modelcontextprotocol/swift-sdk` API surface without declaring the dependency in their own manifest.

**Why:**  
`MCP` types (`Transport`, `Server`, `Tool`, etc.) appear in `SWAMCPServer`'s `public` API: `start(transport: any Transport)` and `stop()`. Re-exporting is therefore marginally justified for `Transport`. However, the full re-export also exposes `Value`, `Resource`, `MCPError`, and all other MCP types. Consumers who accidentally reference these types will break when the project changes its `swift-sdk` dependency version or removes the re-export.

**Recommendation:**  
Scope the re-export to only the types that appear in `SWAMCPServer`'s declared public interface. Or make those types `package`-visible and change the `start(transport:)` signature to accept a type-erased or protocol-backed wrapper defined in this module, removing the need for re-export.

---

### F-12

**Severity:** Medium  
**Title:** iOS 18 platform declaration is incompatible with `IndexStoreDB` targets  
**File:** `Package.swift:12`, `Package.swift:137,168`

**What:**  
The package declares `platforms: [.macOS(.v15), .iOS(.v18)]`. However, `UnusedCodeDetector` and `SymbolLookup` both depend on `.product(name: "IndexStoreDB", package: "indexstore-db")`. The `indexstore-db` package does not support iOS — its underlying `libIndexStore.dylib` is a macOS-only toolchain component. SPM will attempt to resolve this dependency for iOS targets.

**Why:**  
Any consumer who builds this package for an iOS target (e.g., to analyze Swift source server-side in an iOS app, or via Catalyst) will encounter a link-time failure. The CI pipeline has no iOS build or test step, so this failure is invisible in CI. The `test-linux` job documents a similar problem ("IndexStore mode is macOS-only") but leaves the iOS scenario unaddressed.

**Recommendation:**  
Either remove `.iOS(.v18)` from the platform list (the entire package is macOS-oriented: `O_NOFOLLOW`, `IndexStoreDB`, `libIndexStore`), or refactor `IndexStoreDB`-dependent code behind `#if canImport(Darwin) && !targetEnvironment(macCatalyst)` guards and test the iOS build in CI.

---

### F-13

**Severity:** Medium  
**Title:** CI `duplicates-check` and `unused-check` steps gate on findings (exit code 2) without documentation or a way to suppress  
**File:** `.github/workflows/ci.yml:107-137`

**What:**  
Both `swa duplicates Sources ...` and `swa unused Sources ...` are invoked without `|| true` or `continue-on-error`. Now that exit code 2 is properly wired (CHANGELOG sweep 1 fix), if the project itself has any clone group above 100 tokens or any unreachable symbol in reachability mode, these CI steps fail and block the `test` stage.

**Why:**  
This is likely the intended behavior — self-eat-your-own-dogfood gates. However, there is no documented process for contributors to understand why CI is blocked in Stage 1, no annotation in the workflow about the expected exit code contract, and no path for a project maintainer to add a `// swa:ignore` suppression when an architectural duplicate is intentional. The first time a contributor adds a legitimate duplicate (e.g., a test fixture that intentionally duplicates source), CI will block their PR with no clear remediation path shown in the workflow output.

**Recommendation:**  
Add a workflow-level comment explaining exit code 2 is a findings gate. Consider running these steps with `|| exit 0` and piping output to a PR annotation action, treating them as informational rather than hard gates for now. Alternatively, add `--sensible-defaults` and an explicit `--min-tokens` floor to the `duplicates-check` that makes the threshold conservative enough not to fire on the existing codebase.

---

### F-14

**Severity:** Medium  
**Title:** `swa-bench` imports both the `SwiftStaticAnalysis` umbrella and its constituent modules redundantly  
**File:** `Sources/swa-bench/main.swift:5-17`, `Package.swift:270-284`

**What:**  
`swa-bench/main.swift` imports `SwiftStaticAnalysis` (which `@_exported`-re-exports `DuplicationDetector`, `SwiftStaticAnalysisCore`, `SymbolLookup`, `UnusedCodeDetector`) and then also imports each of those modules individually. In `Package.swift`, `swa-bench`'s `dependencies` array lists both `SwiftStaticAnalysis` and its constituent targets.

**Why:**  
The redundant explicit imports are harmless at compile time but signal that the author did not know that `SwiftStaticAnalysis` already re-exports everything. The `Package.swift` dependencies are redundant: declaring both `SwiftStaticAnalysis` and `DuplicationDetector`/`UnusedCodeDetector`/`SymbolLookup` means the linker sees duplicate symbols from the same modules, which SPM resolves without error but which creates a larger-than-necessary manifest surface to maintain.

**Recommendation:**  
Remove the individual target names from `swa-bench`'s `dependencies` list in `Package.swift` and keep only `SwiftStaticAnalysis` and `SwiftStaticAnalysisCore` (the latter for types not re-exported by the umbrella). Remove the redundant `import` statements from `main.swift`.

---

### F-15

**Severity:** Medium  
**Title:** `benchmarks.yml` omits the `duplicates-semantic` scenario  
**File:** `.github/workflows/benchmarks.yml:39`

**What:**  
The benchmark workflow runs five scenarios: `duplicates-exact duplicates-near unused-simple unused-reachability symbol-lookup`. The `swa-bench` binary defines six `BenchmarkScenario` cases — the sixth, `duplicatesSemantic = "duplicates-semantic"`, is absent from the CI run.

**Why:**  
The semantic clone detector (AST fingerprinting path) is the most CPU-intensive algorithm. Its absence from the benchmark gate means performance regressions to `SemanticCloneDetector` or `ASTFingerprintVisitor` will not be caught before they reach `main`.

**Recommendation:**  
Add `duplicates-semantic` to the scenario loop in `benchmarks.yml`. If semantic clone detection is too slow to run on the `Sources/` fixture in CI, document a `--min-tokens` threshold that makes it tractable, or use a smaller fixture.

---

### F-16

**Severity:** Low  
**Title:** `README.md` SPM installation snippet is pinned to `0.1.4`, not the current release  
**File:** `README.md:40`

**What:**  
```swift
.package(url: "https://github.com/g-cqd/SwiftStaticAnalysis.git", from: "0.1.4")
```
The package is at version 0.2.0 with breaking changes since 0.1.4.

**Why:**  
A consumer following the README will install a version that is missing the `Bitmap`/`AtomicBitmap` move, the `SWAConfiguration.format` type change, and the CLI enum-mirror removal. They will get the pre-audit-remediation version with known security issues.

**Recommendation:**  
Update the version pin to `from: "0.2.0"` and add a note about breaking changes since 0.1.x. Also update `SECURITY.md:4` which still lists only `0.1.x` as supported.

---

### F-17

**Severity:** Low  
**Title:** `ProcessExecutor` and `FNV1a` are `public` despite being internal infrastructure  
**File:** `Sources/SwiftStaticAnalysisCore/Utilities/ProcessExecutor.swift:23`, `Sources/SwiftStaticAnalysisCore/Utilities/FNV1a.swift:16`

**What:**  
`ProcessExecutor` is a subprocess launcher with an environment allowlist. `FNV1a` is a hash utility. Both are `public`. Neither type appears in any other module's public API signature.

**Why:**  
Making subprocess-launcher semantics public is especially risky: a consumer who calls `ProcessExecutor.run` with their own `executable` and `arguments` would bypass their own safety guardrails and is not a use case the library should support. `FNV1a` is benign but unnecessary surface.

**Recommendation:**  
Demote both to `internal` or `package`. If `ProcessExecutor.scrubbedEnvironment` needs to be visible in tests, use `@testable import` in test targets.

---

### F-18

**Severity:** Low  
**Title:** `swa-mcp` command-line argument parsing is hand-rolled instead of using `ArgumentParser`  
**File:** `Sources/swa-mcp/main.swift:17-46`

**What:**  
`swa-mcp` manually scans `CommandLine.arguments` to find `--path`, `-p`, `--help`, `--version`. The `swa` CLI uses `swift-argument-parser` for identical functionality.

**Why:**  
Hand-rolled argument parsing does not handle edge cases (flag attached to value with `=`, duplicate flags, `--` separator, etc.). If a path is passed as `--path=/some/path` instead of `--path /some/path`, the parser silently sets `codebasePath = nil`. This is inconsistency with the rest of the toolchain, not a security issue.

**Recommendation:**  
Port `swa-mcp` to `ArgumentParser`. The `swa-mcp` target already has `swift-sdk` as a dependency; adding `swift-argument-parser` is a single line. Use `@Argument` for the positional path.

---

### F-19

**Severity:** Low  
**Title:** `UnusedConfiguration.excludeNamePatterns` field is declared in the config struct but never consumed in the CLI merge path  
**File:** `Sources/SwiftStaticAnalysisCore/Configuration/SWAConfiguration.swift:185`, `Sources/swa/SWA.swift:391-403`

**What:**  
`UnusedConfiguration.excludeNamePatterns` is a `[String]?` field with documentation. `UnusedCodeFilterConfiguration` and `UnusedCodeFilter` both accept `excludeNamePatterns`. However, `buildUnusedConfig(from:)` and the `Unused.run()` inline merge in `swa/SWA.swift` never forward `config.unused?.excludeNamePatterns` to the detector or filter.

**Why:**  
A user who sets `excludeNamePatterns` in `.swa.json` will have that field silently ignored when running `swa unused`. This is a quiet correctness failure.

**Recommendation:**  
Wire `config.unused?.excludeNamePatterns` through `buildUnusedConfig` into `UnusedCodeConfiguration.ignoredPatterns`, or remove the field from `UnusedConfiguration` if it is intentionally not CLI-exposed. Add a test case.

---

### F-20

**Severity:** Low  
**Title:** `getCodebaseInfo` in `CodebaseContext` reads every file with `String(contentsOfFile:)` rather than using `MemoryMappedFile`  
**File:** `Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift:198`

**What:**  
```swift
if let content = try? String(contentsOfFile: file, encoding: .utf8) {
    totalLines += content.utf8.lazy.count(where: { $0 == 0x0A }) + 1
}
```
This allocates a full `String` per file solely to count newlines. The codebase already has `MemoryMappedFile` for zero-copy byte scanning and a memoized `findLineRanges`.

**Why:**  
For a codebase with 116 files this is not a performance problem in practice, but it contradicts the "hot-path mmap wiring" claim in the CHANGELOG and creates a latency spike every time `get_codebase_info` is called from an MCP client. The `MemoryMappedFile` approach would avoid the UTF-8 transcoding and heap allocation.

**Recommendation:**  
Replace with `MemoryMappedFile` + a byte scan for `0x0A` newlines, wrapped in a `do { } catch {}` to handle empty files. Alternatively, use the memoized `SourceFileReader.readLines`.

---

### F-21

**Severity:** Low  
**Title:** `AnalysisLogger` is `public` with an `osLog` default case that silently no-ops on Linux  
**File:** `Sources/SwiftStaticAnalysisCore/Utilities/AnalysisLogger.swift:20`

**What:**  
`AnalysisLogger` is a `public struct` with an `osLog(category:)` factory case as the default in `UnusedCodeConfiguration.init`. On Linux (the `swift:6.0-noble` CI leg), `os_log` is unavailable; the logger would need to fall back to `print` or be a no-op.

**Why:**  
The Linux CI step was added in sweep 2 and is still `continue-on-error: true`. If the logger compile-fails or silently degrades on Linux, diagnostics from the analysis runs would be lost and the Linux test would still be marked as passing-with-warning. Making an internal logging utility `public` also adds API churn when the logger strategy evolves.

**Recommendation:**  
Make `AnalysisLogger` `internal`. Expose configuration of logging as a protocol-typed parameter in public APIs where needed. Add a `#if canImport(OSLog)` / `#else` guard inside the implementation.

---

### F-22

**Severity:** Nit  
**Title:** `SWAConfiguration.validate` validates `format` via `OutputFormat.Codable` conformance but the `allowedDetectionModes` array is a `[String]` that duplicates `DetectionMode.allCases`  
**File:** `Sources/SwiftStaticAnalysisCore/Configuration/ConfigurationLoader.swift:165-168`

**What:**  
```swift
static let allowedDetectionModes = ["simple", "reachability", "indexStore"]
static let allowedConfidences = ["low", "medium", "high"]
static let allowedAlgorithms = ["rollingHash", "suffixArray", "minHashLSH"]
static let allowedCloneTypes = ["exact", "near", "semantic"]
```
These are manually maintained string arrays that shadow the `rawValue`s of their respective enums (`DetectionMode`, `Confidence`, `DetectionAlgorithm`, `CloneType`). Any enum case addition or rename requires updating both places.

**Why:**  
This is a maintainability smell. The strings can be derived from `CaseIterable.allCases.map(\.rawValue)` at the call site, eliminating the duplication.

**Recommendation:**  
Replace each static array with `DetectionMode.allCases.map(\.rawValue)` etc. This requires that `DetectionMode`, `Confidence`, `DetectionAlgorithm`, and `CloneType` conform to `CaseIterable` — which `Confidence` already does (`UnusedCodeTypes.swift:31`), and `CloneType` and `DetectionMode` likely do as well.

---

### F-23

**Severity:** Nit  
**Title:** `StaticAnalysisCommandPlugin` declares `permissions: []` but spawns a `Process` inline  
**File:** `Sources/StaticAnalysisCommandPlugin/Plugin.swift:52-79`, `Package.swift:207-213`

**What:**  
The command plugin's declaration has `permissions: []`. The plugin body runs `Process()` twice (once per analysis type), which in a sandboxed SPM build host requires the `allowNetworkConnections` or `writeToPackageDirectory` permission — or relies on the fact that the `swa` tool is a declared plugin dependency and is therefore trusted. The plugin does NOT use `ProcessExecutor` (the env-scrubbed launcher), so the two `Process` invocations inherit the full parent environment.

**Why:**  
The SECURITY.md explicitly notes: "The SPM plugin host (`StaticAnalysisCommandPlugin`) is sandbox-locked to `PackagePlugin + Foundation` and cannot use `ProcessExecutor`; its two `Process` invocations remain in-place." This is documented as a known gap. The inherited environment includes `DYLD_INSERT_LIBRARIES` and other injection vectors that `ProcessExecutor` scrubs. For plugins, SPM itself provides some sandboxing, but the plugin could still be influenced by a hostile environment.

**Recommendation:**  
This is an accepted limitation per SECURITY.md, but it should be explicitly tested in CI: run the command plugin under a hostile environment to verify SPM's own sandbox prevents injection. Document whether the `permissions: []` declaration is intentional or an oversight (the plugin may need `allowNetworkConnections` for `xcrun` calls if the `swa` binary invokes it).

---

### F-24

**Severity:** Nit  
**Title:** `StaticAnalysisBuildPlugin` uses `.prebuildCommand` which runs before every build, potentially causing unexpected latency  
**File:** `Sources/StaticAnalysisBuildPlugin/Plugin.swift:43-50`

**What:**  
The build plugin registers a `.prebuildCommand`. SPM prebuild commands run unconditionally before every incremental build, not only when source files change. For a large codebase, running `swa analyze` on every `swift build` would add seconds of latency even for a one-line change.

**Why:**  
The intended use case is Xcode warning integration, where latency is more acceptable and the user triggers builds infrequently. However, `swift build` users (including CI) would incur this cost on every invocation. The CHANGELOG does not document any input-file dependency tracking that would allow SPM to skip the step when no Swift files changed.

**Recommendation:**  
Add source file inputs to the prebuild command declaration (the `sources.map(\.url)` list) so SPM's build system can skip the step when no input has changed. Alternatively, change this to a build command (not prebuild) so it runs only when explicitly requested or when SPM determines inputs have changed.

---

## Strengths

1. **Module graph cycle resolution is genuine.** The Bitmap/AtomicBitmap move from `UnusedCodeDetector` to `SwiftStaticAnalysisCore` cleanly severed the prior cycle. The Package.swift comment and CHANGELOG both document the rationale. No reverse-dependency cycles remain in the current graph.

2. **MCP sandbox hardening is thorough.** `CodebaseContext.validatePath` uses separator-aware prefix checking after symlink resolution, correctly closing both the sibling-path-bypass attack and the symlink-escape attack. The `handleReadFile` path enforces a regular-file check, a size cap, an extension allowlist, and validates line ranges before slicing — all at a single, shared validation function (`validateForReadFile`). The `handleSearchSymbols` ReDoS mitigations (query length cap, static antipattern rejection, per-match name length cap, wall-clock budget) are defense-in-depth.

3. **Swift 6 strict concurrency is applied consistently.** Every module declares `.swiftLanguageMode(.v6)` and `.enableExperimentalFeature("StrictConcurrency")`. The migration away from `@unchecked Sendable` on `MemoryMappedFile`, `FileSlice`, `ArenaTokenStorage`, and `AtomicBitmap` is correctly documented in the CHANGELOG as a scope-limited removal, not a blanket suppression.

4. **Exit code contract is correctly wired.** All three analysis subcommands (`analyze`, `duplicates`, `unused`) throw `ExitCode(2)` on findings, `ValidationError` (which `ArgumentParser` maps to exit 64) on invalid flag values, and propagate `throw` (exit 1) on I/O errors. The `symbol` subcommand correctly stays at exit 0 as an informational command. The `--report` mode correctly returns 0.

5. **ProcessExecutor environment scrubbing is principled.** The allowlist (`PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LC_MESSAGES`, `TMPDIR`, `TERM`) is conservative and explicitly excludes `DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`, `SWIFTPM_HOOKS_DIR`, and `BASH_ENV`. The decision not to adopt `swift-subprocess` (pre-1.0) and to stay on Foundation `Process` after the env scrub is pragmatically correct.

6. **Config validation at load boundary is correct.** `ConfigurationLoader.loadFromFile` calls `configuration.validate(path:)` immediately after decoding, using typed throws (`throws(ConfigurationError)`). Unknown enum strings in `.swa.json` are rejected with a structured error message before they can propagate to detectors as silently-defaulted values.

7. **`swa analyze`/`swa unused` parity fix is verified.** The defaults for `treat-*-as-root` flags were unified to `true` in both `buildUnusedConfig` and `Unused.run()`. The fix is documented in CHANGELOG with a comment in `buildUnusedConfig` explaining the historical discrepancy.

8. **Glob metacharacter escaping in `CodebaseContext.matchesGlobPattern` is complete.** The character-by-character escape loop covers `+`, `(`, `)`, `[`, `]`, `{`, `}`, `^`, `$`, `|`, `\`, and `?` — the full set of regex metacharacters that glob does not use. The previous implementation's single `.`-only escape was a ReDoS vector.

9. **`DenseGraph` + `ParallelBFS` reachability is architecturally clean.** The `DenseGraph` struct correctly separates the projection step from the analysis step and caches the projection per actor. `Bitmap`-based BFS visited-set tracking and the `Beamer et al.` direction-optimizing threshold are sound implementations of known performance techniques.

10. **Umbrella product split (`SwiftStaticAnalysis` vs `SwiftStaticAnalysisAll`) is correct.** Consumers who only need the analyzer libraries do not pull in `modelcontextprotocol/swift-sdk`. The distinction is documented in both `Package.swift` and the module docstrings.

---

## Recommended Next Steps

Priority order based on user impact × fix cost:

1. **[High, low cost]** Fix the `--parallel` flag to map to `.safe` per the README contract (`swa/SWA.swift:207,370`). One-line change per subcommand; add a test case to `CLITests`.

2. **[High, medium cost]** Fix the stale README version pin from `0.1.4` to `0.2.0` and update `SECURITY.md` supported versions table. Also bump the MCP server version literal from `"0.1.0"` to `"0.2.0"` in `SWAMCPServer.swift:49`.

3. **[High, medium cost]** Consolidate glob-matching into a single `GlobMatcher` in `SwiftStaticAnalysisCore` with consistent `wholeMatch` semantics. Remove the duplicate implementations in `UnusedCodeFilter` and `CodebaseContext`.

4. **[High, high cost]** Move `IndexStoreReader` (and related types) from `UnusedCodeDetector/IndexStore/` to `SwiftStaticAnalysisCore/IndexStore/`. This eliminates the `SymbolLookup → UnusedCodeDetector` dependency inversion and is the highest-leverage structural improvement.

5. **[Medium, low cost]** Demote CFG/dataflow types (`VariableID`, `BlockID`, `BasicBlock`, `ControlFlowGraph`, `CFGBuilder`, `CFGStatement`, `Terminator`) from `public` to `internal`. Run `swift build` and fix any test import issues with `@testable`.

6. **[Medium, low cost]** Delete `canonicalizePath` from `swa/SWA.swift` and replace with `PathUtilities.canonicalize`. Both functions are available in the same binary.

7. **[Medium, low cost]** Wire `UnusedConfiguration.excludeNamePatterns` through `buildUnusedConfig` into `UnusedCodeConfiguration.ignoredPatterns`. Add a regression test.

8. **[Medium, low cost]** Add `duplicates-semantic` to the benchmark scenario loop in `benchmarks.yml`.

9. **[Medium, medium cost]** Add `StaticAnalysisBuildPlugin` source-file input declarations to enable incremental build skipping.

10. **[Low, low cost]** Demote `ProcessExecutor`, `FNV1a`, and `AnalysisLogger` to `internal`. Demote `SwiftStaticAnalysisMCP`'s `@_exported import MCP` to a targeted export of only the types in the public API surface.
