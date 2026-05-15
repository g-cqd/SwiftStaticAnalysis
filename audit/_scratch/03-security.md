# Security Audit — SwiftStaticAnalysis (swa / swa-mcp)

Audit date: 2026-05-15
Scope: full repository, head of `main` (commit `19c8db4`).
Auditor: defensive-tooling security review.

---

## Summary

SwiftStaticAnalysis is a defensive Swift static-analysis CLI plus an MCP server
that exposes seven tools to an LLM client over stdio. The MCP server is the
primary attack surface: untrusted assistant prompts can drive
`read_file`, `analyze_file`, `list_swift_files`, `search_symbols`,
`detect_unused_code`, `detect_duplicates`, `get_codebase_info`, all of which
take a `codebase_path` (and frequently a `path`) that originate from
attacker-controlled content (LLM input, tool arguments synthesised by an
agent reading a hostile repository, etc.).

The project has been **noticeably hardened** in the v0.2 cycle. The three
commits called out in the brief — *ReadResource hardening*, *Process
environment allowlist*, *regex wedge* — are each substantive and largely
correct. Centralisation of the read-file validation (`validateForReadFile`,
shared between the `read_file` tool and the `ReadResource` handler) is a
textbook example of avoiding security-control drift between two surfaces
that share a sandbox boundary. `ProcessExecutor`'s allowlist closes
`DYLD_INSERT_LIBRARIES` / `DEVELOPER_DIR` / `SWIFTPM_HOOKS_DIR` injection
into `swift build` and `xcrun --find swift`. `MemoryMappedFile` rejects
non-regular files, applies `O_NOFOLLOW`, and caps mappings at 256 MiB.
`search_symbols` enforces a regex query-length cap, a static
nested-quantifier prefilter, and a 2.5 s wall-clock budget.

That said, several real issues remain. The most consequential are:

1. **`detect_unused_code.index_store_path` is not sandbox-validated** before
   being passed into `IndexStoreDB` / `createDirectory(withIntermediateDirectories:)`.
   An attacker who can call the MCP tool can (a) point the index reader at
   an arbitrary on-disk directory outside the codebase root and (b) cause
   `IndexDatabase/` to be **created** as a sibling of that directory —
   filesystem write outside the sandbox.
2. **`ReadResource` URI parsing is naive**. `String(uri.dropFirst(7))` is
   applied to the literal `file://…` string with no percent-decoding and
   no host-component handling. A URI of the form
   `file://attacker.example/etc/passwd` is silently reduced to
   `attacker.example/etc/passwd` and then fed to `validatePath`, which is
   resilient — but a URI containing percent-encoded `/` or `..` will not
   be decoded prior to canonicalisation, so a defender ends up trusting
   a stale boundary check.
3. **`contextCache` in `SWAMCPServer` is unbounded**. A hostile assistant
   can flood the server with thousands of `codebase_path` values, each
   constructing a fresh `CodebaseContext` and pinning it in memory. The
   parsing `SwiftFileParser` is bounded (LRU 256), but `contextCache`
   is not.
4. **Glob-pattern regex translation in `CodebaseContext.matchesGlobPattern`
   is reachable from MCP tool arguments and uses runtime-compiled
   `Regex` without any timeout or anti-ReDoS check**. The static
   antipattern prefilter only fires on `search_symbols`.
5. **Plugin `Process` invocations bypass `ProcessExecutor`**. Per
   `SECURITY.md` this is a documented limitation (SPM plugin sandbox
   forbids the import), but the plugin still inherits the parent
   environment — including `DYLD_INSERT_LIBRARIES` — when executing the
   `swa` tool. The blast radius is limited (the plugin runs in the SPM
   sandbox), but a documented limitation should also have a documented
   mitigation in code (e.g. `process.environment = [:]`).
6. **`AtomicBitmap.popCount` is documented as a non-atomic snapshot** but
   is otherwise sound. The `@unchecked Sendable` / `nonisolated(unsafe)`
   pile is well-justified at every site.

**Overall risk rating: LOW-to-MEDIUM**. None of the findings constitute
a remote-code-execution chain against the `swa` host; the worst realistic
outcome from an attacker-controlled MCP prompt is (a) filesystem
write of an `IndexDatabase/` directory at an arbitrary location reachable
by the MCP process and (b) read access to non-source files that share an
allowlisted extension. The hardening already in place is correct and
well-reasoned; the gaps below are the natural ones a careful reviewer
would catch in v0.3.

---

## Findings

### CRITICAL — none

No critical findings. The Swift 6 strict-concurrency baseline, mandatory
process-environment scrubbing on all non-plugin subprocess invocations,
and the read-file extension allowlist together preclude the highest-impact
classes (DYLD-based code injection, arbitrary-binary read).

---

### HIGH-1 — `index_store_path` MCP argument bypasses the sandbox; can trigger filesystem writes outside the codebase

**CWE-22, CWE-73** (Path traversal / external control of filename)

`Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:583-586`

```swift
// Index store path
if let indexStorePath = args["index_store_path"]?.stringValue {
    config.indexStorePath = indexStorePath
}
```

`config.indexStorePath` is passed without validation through to
`IndexStoreAnalyzer.detect(in:indexStorePath:)`
(`Sources/UnusedCodeDetector/IndexStore/IndexStoreAnalyzer.swift:218-220`)
which constructs `IndexStoreReader(indexStorePath: indexStorePath)`. That
initialiser builds `databasePath = storePath.deletingLastPathComponent()
.appendingPathComponent("IndexDatabase")` and then calls
`FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)`
at `Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift:249`.

**Attack scenario.** The MCP client calls
```
detect_unused_code {
  "codebase_path": "/Users/victim/safe-project",
  "index_store_path": "/Users/victim/.ssh/marker"
}
```
The server creates `/Users/victim/.ssh/IndexDatabase/` (write outside the
sandbox) and then opens an `IndexStoreDB` rooted at `.ssh/marker`. The
write is the more interesting half: it survives the call and is
attacker-attributable. With a path like
`/Users/victim/Library/LaunchAgents/IndexDatabase` (a sibling of an
existing config file) the attacker creates a directory at a privileged
location.

**Why it's exploitable.** `index_store_path` is read straight off the
MCP wire and assigned to `config.indexStorePath` with no
`context.validatePath` call. The detector then performs unconditional
on-disk operations.

**Remediation.** In `handleDetectUnusedCode`, gate the assignment:
```swift
if let indexStorePath = args["index_store_path"]?.stringValue {
    config.indexStorePath = try context.validatePath(indexStorePath)
}
```
For defence in depth, `IndexStoreReader.init` should refuse to create
`IndexDatabase/` outside a caller-supplied sandbox root, and require the
caller to opt into directory creation (`createDirectory` should not be
implicit for a "reader").

Additionally: this is one of two MCP arguments that takes a path string
(the other is `codebase_path`). Audit all `String` MCP arguments that
end up at a filesystem call and route them through `validatePath` at the
edge of the tool handler.

---

### HIGH-2 — `ReadResource` URI parsing skips percent-decoding and host-component handling

**CWE-20** (Improper Input Validation), **CWE-23** (Relative Path Traversal)

`Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:1101-1116`

```swift
guard uri.hasPrefix("file://") else {
    throw MCPError.invalidRequest("Only file:// URIs are supported")
}
…
let path = String(uri.dropFirst(7))
…
let validatedPath = try context.validatePath(path)
```

This drops the `file://` literal prefix and treats the remainder as a
filesystem path. RFC 8089 `file:` URIs may carry:

- A non-empty host segment: `file://example.com/etc/passwd` — the
  current code yields `example.com/etc/passwd`, which `validatePath`
  treats as a relative path under `rootPath`. That's *safe* against
  exfiltration because the canonicalisation still keeps it within the
  sandbox, but the failure mode is silent: a caller expecting
  "host-bearing URIs are rejected" gets a fallback to a sandbox-internal
  lookup that succeeds against any file matching that suffix.
- Percent-encoded path components: `file:///a%2F..%2F..%2Fetc/passwd`
  would canonicalise to a sandbox-internal `a%2F..%2F..%2Fetc/passwd`
  pathname (also safe today by accident — the literal `%2F` is treated
  as filename, not separator) but the moment the validator is
  refactored to decode early or the sandbox layer becomes URI-aware,
  this turns into a traversal.

**Why it matters.** Today the bug is latent because `validatePath`
canonicalises the (literal, non-decoded) string and the sandbox prefix
check still holds. But the surface is fragile: any future change that
decodes `%xx` before the sandbox check, or that adopts
`URL(string: uri)?.path` to "improve" parsing, instantly converts this
into a sandbox-escape path. Using `URL(string:)?.path` *correctly* is the
right fix and is also more honest about what's accepted.

**Remediation.**
```swift
guard let parsed = URL(string: uri),
      parsed.scheme == "file",
      parsed.host == nil || parsed.host?.isEmpty == true
else {
    throw MCPError.invalidRequest("Only local file:// URIs are supported")
}
let path = parsed.path  // already percent-decoded
let validatedPath = try context.validatePath(path)
```

This also gives free protection against `file:` URIs with query strings
or fragments that the literal-prefix strip silently passes through.

---

### HIGH-3 — `contextCache` in `SWAMCPServer` is unbounded; memory-exhaustion DoS

**CWE-770** (Allocation of Resources Without Limits or Throttling)

`Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:23, 67-79`

```swift
private var contextCache: [String: CodebaseContext] = [:]
…
let context = try CodebaseContext(rootPath: resolvedPath)
contextCache[resolvedPath] = context
```

Every distinct `codebase_path` is canonicalised and pinned in
`contextCache` for the lifetime of the actor (the MCP server). The
`SwiftFileParser` cache is correctly bounded to 256 entries via LRU
(SwiftFileParser.swift:29-31, 152-168) and `RegexCache` is bounded
(RegexCache.swift:29). The MCP context cache is the outlier.

**Attack scenario.** An LLM client (whether confused, jailbroken, or
deliberately malicious) issues 50,000 tool calls each with a unique
synthetic `codebase_path` (e.g. created by mkdir'ing under `/tmp/`).
Each `CodebaseContext` is small in isolation, but at scale the
collection grows without bound. Worse, `findSwiftFiles` is invoked
opportunistically by every tool, so the per-context page-cache and
Foundation enumerator state grow too. A long-running `swa-mcp` session
that survives many minutes is realistic.

**Why it's exploitable.** `swa-mcp` is designed to be long-lived (it
parks on `Task.sleep(for: .seconds(.greatestFiniteMagnitude))`,
main.swift:81). There's no per-process resource cap, no eviction policy.

**Remediation.** Bound the cache the same way `SwiftFileParser` does:
```swift
private var contextCache: OrderedDictionary<String, CodebaseContext> = [:]
private let contextCacheLimit = 32

private func cacheContext(_ ctx: CodebaseContext, for key: String) {
    if contextCache[key] == nil, contextCache.count >= contextCacheLimit {
        contextCache.removeFirst()
    }
    contextCache[key] = ctx
}
```
32 distinct codebases per session is generous; most workflows touch
1–3.

A defensive secondary control: add a per-method rate limiter (token
bucket) that bounds tool invocations per minute. Even without a
malicious caller, a chatty LLM can produce hundreds of calls per
second.

---

### HIGH-4 — Glob-pattern compilation is reachable from MCP arguments and lacks ReDoS guards

**CWE-1333** (Inefficient Regular Expression Complexity)

`Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift:153-181`
`Sources/UnusedCodeDetector/Filters/UnusedCodeFilter.swift:211-250`

`CodebaseContext.matchesGlobPattern` is invoked via
`findSwiftFiles(excludePatterns:)` and ultimately reachable from
`list_swift_files` (SWAMCPServer.swift:497-510) with caller-controlled
`exclude_patterns`. The translation escapes most regex metacharacters
but allows `**` to become `.*` and `*` to become `[^/]*`. Two
exposures:

1. The static antipattern prefilter (`reDoSAntipatterns` at
   SWAMCPServer.swift:833) is **only applied in `handleSearchSymbols`**.
   The same `Regex` engine is asked to compile and run user-supplied
   patterns through `matchesGlobPattern` with no anti-ReDoS check and
   no wall-clock budget.
2. A glob like `**a*b*c*d*e*f*g*h*i*j*k*l*m*n*o*p*q*r*s*t` translates
   to `.*a[^/]*b[^/]*…` which is not catastrophic by itself but, when
   evaluated against every directory entry in a large codebase via
   `path.wholeMatch(of: regex)`, gives the attacker an O(n·m·k)
   resource sink where n=files, m=pattern length, k=path length.
   `Regex<…>.wholeMatch(of:)` does not have a runtime budget in the
   stdlib regex engine.

The same observation applies to `UnusedCodeFilter.matchesGlobPattern`
called via `detect_unused_code` and `detect_duplicates`
`exclude_paths`.

**Attack scenario.** A confused LLM agent constructs an
`exclude_patterns` list of 100 long, pathological globs. Each is
compiled and matched against every Swift file in the codebase.

**Why it's exploitable.** Same reason as `search_symbols` was — the
project already accepts that runtime-supplied regex needs guarding, but
the protection lives in the search handler instead of the regex
helper.

**Remediation.**

- Centralise the ReDoS antipattern check and pattern-length cap in
  `RegexCache` (or a sibling `ValidatedRegex.compile(_:budget:)` helper)
  and route every user-input regex compilation through it. The current
  pattern of duplicating the antipattern list will silently rot.
- Cap the number of `exclude_patterns` accepted in a single call
  (e.g. 32). 32 globs is more than any legitimate config uses.
- Cap each pattern's length (256 chars matches `search_symbols`).
- Optionally enforce a wall-clock budget across the whole filter pass
  using the same `ContinuousClock`-based pattern as `handleSearchSymbols`
  (SWAMCPServer.swift:898-905).

---

### MEDIUM-1 — Plugin `Process` invocations inherit the full parent environment

**CWE-426** (Untrusted Search Path), **CWE-829** (Inclusion of Functionality from Untrusted Control Sphere)

`Sources/StaticAnalysisCommandPlugin/Plugin.swift:51-61, 123-133`

Per `SECURITY.md` lines 88-90, the plugin host cannot import
`ProcessExecutor` (the SPM plugin sandbox is restricted to
`PackagePlugin + Foundation`). However, the workaround chosen — invoke
`Process` directly with no environment scrubbing — means the child
`swa` tool inherits `DYLD_INSERT_LIBRARIES`, `DEVELOPER_DIR`,
`SWIFTPM_HOOKS_DIR`, `PATH`, etc. from the SPM plugin host's process.

**Attack scenario.** Developer A runs
`DYLD_INSERT_LIBRARIES=/tmp/evil.dylib swift package analyze`. The
plugin inherits `DYLD_INSERT_LIBRARIES`, forks `swa`, and the dylib is
loaded into `swa`. Not a remote attack but it is a privilege-laundering
vector when the plugin is invoked from a build automation pipeline
that the attacker has touched.

**Why it's mostly contained.** The SPM plugin sandbox refuses
filesystem writes outside the plugin work directory, so the impact of
the injected dylib is limited to whatever `swa` reads. But `swa` will
happily print the contents of any file it can read, which is exactly
what an attacker wants.

**Remediation.** Even from within the plugin sandbox you can still
build an explicit environment dictionary literally — no
`ProcessExecutor` import required:
```swift
process.environment = [
    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    "HOME": ProcessInfo.processInfo.environment["HOME"] ?? "",
    "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "C",
]
```
Inline this same allowlist in `Plugin.swift`. Two call sites, eight
lines of copy-paste. Don't let the documented limitation stay
unmitigated.

---

### MEDIUM-2 — `read_file` extension allowlist accepts `.plist`, `.json`, `.yaml` — exfiltration of project config

**CWE-200** (Exposure of Sensitive Information to an Unauthorized Actor)

`Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:676-678`

```swift
static let readFileAllowedExtensions: Set<String> = [
    "swift", "md", "json", "yml", "yaml", "txt", "toml", "plist",
]
```

The allowlist exists to prevent an attacker reading binaries / device
files / log files. It accepts plain-text data formats so the assistant
can read `Package.swift`'s sibling `*.json`, etc.

This is appropriate for the documented use case, **but** many projects
keep credentials in `*.json` (`.npmrc`, `firebase-credentials.json`,
service-account JSON), `*.yaml` (`ci/secrets.yaml`, `kustomize`
overrides), or `*.plist` (`GoogleService-Info.plist`). Once the
sandbox is rooted at the project, the assistant has read access to
all of those by extension.

**Attack scenario.** A repository contains
`fixtures/integration/aws-creds.json` checked in (it shouldn't be, but
people do). The LLM, prompted to "review the fixtures directory,"
issues `read_file` calls that surface those credentials in the model's
context, which is then potentially shipped to the model provider.

**Why it's exploitable.** The MCP boundary trusts the assistant's
file selection, but the developer running `swa-mcp` against their
project did not necessarily audit every file with a permitted
extension.

**Remediation (defence in depth, not a strict bug).**

- Document the extension list and its trust assumption (the README's
  "MCP Sandbox" section currently doesn't enumerate them).
- Add an optional, off-by-default `--deny-pattern` flag that
  short-circuits `read_file` for paths matching common-credential
  globs (`**/*credentials*`, `**/*.pem`, `**/*-secrets.*`).
- Consider downgrading `.plist` from the allowlist — Swift projects
  rarely need `Info.plist` for static analysis, and binary plists
  decoded as UTF-8 will surface garbage anyway.
- Stronger: gate the `read_file` tool behind an explicit allowlist of
  glob patterns, configurable at server start (`--allow-glob`). This
  flips the design from "all source files except a tiny denylist" to
  "exactly these files." That's a bigger UX change but is the right
  long-term answer for an LLM-facing surface.

---

### MEDIUM-3 — `MemoryMappedFile` SIGBUS risk on file truncation under us

**CWE-672** (Operation on a Resource after Expiration or Release)

`Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift:122-138`

The file is mapped with `mmap(...PROT_READ, MAP_PRIVATE, fd, 0)` and
the open uses `O_NOFOLLOW`, but the kernel will still deliver `SIGBUS`
if the underlying file is truncated *after* the mapping. For a
defensive CLI scanning a developer's own project, this is essentially
impossible. For `swa-mcp` running against an LLM-driven session that
also has shell access (Claude Code's MCP + Bash), it's plausible.

**Attack scenario.** Adversarial agent runs (a) `analyze_file` on a
target file, then (b) `truncate -s 0` on the same path while the
analysis is in progress. The mapped pages past the new EOF trigger
`SIGBUS` on access, crashing `swa-mcp`. Single-call DoS.

**Why it's exploitable.** No signal handler. The Foundation `Process`
abstraction doesn't help here — the SIGBUS goes to `swa-mcp` itself.

**Remediation.** Two options:

- Install a `SIGBUS` handler that `siglongjmp`s back out of the read
  loop. Realistically hard in Swift because of stack-unwinding
  semantics; the precedent is sqlite's `mremap` retry.
- Use `pread()` (or `read()`) for files in the MCP read path instead
  of `mmap`, accepting the copy. The 4 KiB `mmapThreshold` in
  `SourceFileReader.defaultMmapThreshold` already exists, so the
  policy lever is in place — just raise the threshold for MCP-driven
  reads, or have the MCP path bypass `mmap` entirely.

For a defensive tool, option two is correct: `swa` itself benefits
from mmap (whole-codebase scans), but the MCP `read_file` /
`analyze_file` workflow reads one file at a time on demand and the
copy is irrelevant.

---

### MEDIUM-4 — `getCodebaseInfo` reads every Swift file into memory; unbounded loop

**CWE-770**

`Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift:184-209`

```swift
for file in swiftFiles {
    if let attributes = try? fileManager.attributesOfItem(atPath: file),
        let size = attributes[.size] as? UInt64 { totalBytes += size }
    if let content = try? String(contentsOfFile: file, encoding: .utf8) {
        totalLines += content.utf8.lazy.count(where: { $0 == 0x0A }) + 1
    }
}
```

Every Swift file is read in full into a `String`. The
`MemoryMappedFile` size cap (256 MiB) does **not** apply here because
`String(contentsOfFile:)` is used directly. The 10 MiB cap from
`readFileMaxBytes` does not apply either. A codebase with one
hostile 4 GB `*.swift` file (a symlink to `/dev/random`? — no, those
are excluded; but a real 4 GB file is possible) is a one-shot OOM.

**Why it's contained.** The MCP sandbox guarantees the file is inside
the codebase root and is a regular file. A hostile codebase with a
4 GB Swift file is far-fetched but possible (committed test fixtures
do exist).

**Remediation.** Use `SourceFileReader.readLines` (which routes
through `MemoryMappedFile`'s 256 MiB cap) or stream the file with
`FileHandle`. For line-counting specifically, a 64 KiB streaming
read with a byte-wise newline scan never needs to materialise the
whole file.

---

### LOW-1 — `findSwiftFiles` enumeration is unbounded

**CWE-770**

`Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift:105-150`

The enumerator returns every matching file with no upper bound. A
1-million-file codebase yields a 1-million-element array. The MCP
caller can then optionally apply `limit`, but the bound is applied
after the enumerator has already materialised everything.

**Remediation.** Apply `limit` inside `findSwiftFiles` (pass it down)
or short-circuit the enumerator when the result array reaches a
caller-supplied cap. Default to e.g. 50,000 files server-side.

---

### LOW-2 — `swift-lmdb` dependency floats on `branch: main`

**CWE-1357** (Reliance on Insufficiently Trustworthy Component)

`Package.resolved:104-109`

```json
{
  "identity" : "swift-lmdb",
  …
  "state" : { "branch" : "main", "revision" : "1ad9a2…" }
}
```

`Package.resolved` pins the revision so reproducible builds *do* work,
but the upstream constraint comes from `indexstore-db` (which is
itself pinned by revision in `Package.swift:90`). The
`indexstore-db` pin is good. The transitive `swift-lmdb` pin is by
*branch*, so a future `swift package update` will re-resolve to
whatever `swift-lmdb` HEAD is at that moment.

**Why it matters.** A maintainer running `swift package update`
unwittingly upgrades to whatever `swiftlang/swift-lmdb@main` is then.
For an analysis tool that links a C dependency (LMDB) this is the
exact supply-chain shape that the OpenSSF SLSA framework warns about.

**Remediation.** Not actionable in this repo directly because the
`branch: main` constraint is upstream in `indexstore-db`'s
`Package.swift`. The right control is `--frozen` in CI
(`swift package --frozen build`) so a developer cannot accidentally
re-resolve, plus a documented "pin the lockfile" rule in
`CONTRIBUTING.md`.

`Package.swift:90` already pins `indexstore-db` by revision hash —
good. But verify in CI that `Package.resolved` round-trips: a
`Package.resolved` modified by `swift package update` should fail CI
unless the diff is reviewed.

---

### LOW-3 — Unbounded subprocess stdout/stderr buffering in `ProcessExecutor.run`

**CWE-770**

`Sources/SwiftStaticAnalysisCore/Utilities/ProcessExecutor.swift:78-99`

```swift
let stdoutPipe = Pipe()
…
let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
```

`readDataToEndOfFile()` reads until EOF with no cap. `swift build` on
a project with thousands of compile errors can emit gigabytes of
diagnostics. The whole blob is then held in memory while the
`Result` is constructed, and the caller copies it into
`combined = result.stdout + result.stderr`.

**Why it's contained.** Only `swa` (CLI, not MCP) can reach
`ProcessExecutor` today. MCP `auto_build` is intentionally not
exposed (SECURITY.md:97-99). So the threat model is "developer runs
swa on an enormous build" — not adversarial.

**Remediation.** Add a per-stream cap (e.g. 16 MiB) and truncate with
a "...output truncated" marker. Use the `FileHandle.readabilityHandler`
pattern so the buffer is bounded.

Also: `waitUntilExit()` before reading the pipes is a classic
deadlock shape if the child fills both pipes faster than they're
drained. For long-running children with verbose output the right
pattern is to drain in parallel via background tasks. Today this is
academic (`xcrun --find swift` produces a handful of bytes), but a
future caller of `ProcessExecutor.run` on a verbose child will
deadlock.

---

### LOW-4 — `RegexCache` eviction is FIFO, not LRU

**CWE-693** (Protection Mechanism Failure — minor)

`Sources/SwiftStaticAnalysisCore/Utilities/RegexCache.swift:52-58`

```swift
if storage.cache.count >= capacity,
    let firstKey = storage.cache.keys.first {
    storage.cache.removeValue(forKey: firstKey)
}
```

`Dictionary.keys.first` is **unordered** — Swift's `Dictionary` does
not guarantee insertion order. The behaviour is "evict some random
key when the cache is full," not "evict the least-recently-used key."
The cache still bounds memory, so this isn't a security issue per se
— but if a hot pattern happens to be the one evicted, the regex is
recompiled on every match. The doc string promises LRU.

**Remediation.** Use `OrderedDictionary` from swift-collections (same
type `SwiftFileParser` uses). Three-line change.

---

### LOW-5 — `swift package update` will silently bump dependencies past the `from:` floor

**CWE-1104** (Use of Unmaintained Third Party Components — manageable)

`Package.swift:84-96`

The `swift-syntax`, `swift-argument-parser`, `swift-format`,
`swift-docc-plugin`, `swift-async-algorithms`, `swift-algorithms`,
`swift-collections`, `swift-sdk` dependencies all use `from:` semver
floors — they will resolve to the latest minor release at update
time. For a tool that ships an MCP server consumed by an LLM, the
ideal posture is `exact:`. This is a stylistic /supply-chain hygiene
note more than a vulnerability; `Package.resolved` is the actual
trust anchor.

`indexstore-db` is correctly pinned by `revision:` because it has no
semver releases.

**Remediation.** Consider `.exact("…")` for `swift-sdk` (the MCP
SDK) at minimum, since it's pre-1.0 and the API surface is the LLM
trust boundary.

---

### INFO-1 — Defaults to dynamic-mode (no default codebase) is the secure choice

`Sources/swa-mcp/main.swift:30-46`

Worth recording: when launched with no path, the server requires every
tool call to specify `codebase_path`. That means a hostile assistant
must guess or be told a codebase path; the server doesn't volunteer
its filesystem layout. Good.

---

### INFO-2 — All error paths surface `error.localizedDescription` rather than internal types

`Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift:468-472, 700-707`

Error messages are concise and don't echo file contents or stack
traces. The `ReadFileValidationError.message` strings include the
*caller-supplied* path verbatim — fine, that's caller-known data —
and the allowlist enumeration, which is intentional UX. No internal
filesystem details leak.

---

### INFO-3 — No network surface

The repository contains no `URLSession`, `Socket`, `NWConnection`, or
`URLRequest` use. The only URLs touched are `file://` resource URIs
and the GitHub URLs in `Package.swift` (used at resolve time, not at
runtime). `swa-mcp` communicates only over stdio. Verified by:
```
grep -rn 'URLSession\|NWConnection\|URLRequest' Sources/
# (no hits in non-doc files)
```
SECURITY.md's "No Network Connectivity" claim is accurate.

---

### INFO-4 — `@unchecked Sendable` and `nonisolated(unsafe)` audit

25 occurrences of `@unchecked Sendable` / `nonisolated(unsafe)`, all
in three justified categories:

- **Mmap pointers** (`MemoryMappedFile`, `FileSlice`,
  `ArenaTokenStorage`): immutable `UnsafeRawPointer` into a read-only
  mapping kept alive by reference. Sound.
- **Regex constants** at file scope (`ClosureNormalizer`,
  `RegexPatterns`, `SWAMCPServer.reDoSAntipatterns`,
  `CompiledPatterns`): `Regex<…>` is value-typed, lazily computed once,
  never mutated. Sound; the only reason `nonisolated(unsafe)` is
  necessary is that the stdlib hasn't conformed `Regex` to `Sendable`
  yet.
- **IndexStoreDB wrappers** (`IndexStoreReader`,
  `IndexBasedDependencyGraph`, `IndexStoreResolver`): the underlying
  `IndexStoreDB` is documented as thread-safe for reads, fields are
  immutable after init. Sound, well-documented.

Each callsite has an explanatory doc comment. This is the right way
to do it.

---

### INFO-5 — `AtomicBitmap.popCount` is honestly documented as a non-atomic snapshot

`Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift:108-118`

Per-word relaxed loads, total is a torn read across words. Doc
comment calls this out explicitly. For BFS visited-tracking, the
torn read is irrelevant — the consumer needs the *eventual* count,
not an instantaneous one. Correct as-is.

---

## Defense-in-depth recommendations

These are not bugs — they're hardening that would raise the bar
further.

### 1. Add a per-tool authorization layer

The MCP server treats all seven tools equally. In practice, `read_file`
is much more sensitive than `get_codebase_info` (which leaks only a
count). A simple opt-in capability flag passed at server start —
`swa-mcp --allow-read=false --allow-detect=true` — lets users hand
the binary to an LLM with reduced trust.

### 2. Audit-log all tool invocations to stderr

Currently `swa-mcp` logs only startup messages to stderr. Each tool
invocation, with the resolved sandbox path and outcome (success /
error code), should go to stderr so a developer running the server
under `tee` has a forensic trail. Don't log file contents.

### 3. Document, in code, the MCP trust boundary

A header comment on `SWAMCPServer` that names the trust model
("untrusted assistant input arrives here; every code path must
treat its arguments as adversarial") makes it harder for a future
refactor to bypass the sandbox by accident. The doc-comments already
cover the path-validation rationale on `CodebaseContext`; one
sentence at the top of `SWAMCPServer.swift` would close the loop.

### 4. Fuzz the MCP surface

`SwiftSyntax` is the workhorse, and `swift-syntax` itself has been
fuzzed extensively upstream — that's covered. The two layers most
worth fuzzing in this repo are:

- `CodebaseContext.validatePath` — feed it `..`, percent-encoded
  paths, `///`, NUL bytes, very long strings, `~/foo`, network
  paths (`smb://`), Windows paths.
- `CodebaseContext.matchesGlobPattern` — feed it pathological globs
  and large inputs. Useful smoke test even with stdlib regex's
  current lack of timeouts.

`SwiftTesting`'s parametric tests are a natural home for both.

### 5. Add a SIGTERM / SIGINT handler that exits the actor cleanly

`main.swift:81` parks on `Task.sleep`. Confirm via signal-trap test
that SIGTERM actually cancels the sleep and drains the actor —
otherwise the MCP server appears unresponsive on Ctrl-C and the LLM
host process leaks.

### 6. Pin the MCP SDK exactly

`swift-sdk` (the MCP SDK) is pre-1.0; `from: "0.12.0"` permits any
0.12.x and was already justified in the comment at Package.swift:86-87
by the NetworkTransport race fix in 0.12.0. Switch to
`.exact("0.12.1")` until the SDK reaches 1.0 — that's the SDK whose
behaviour was actually audited.

### 7. Run `swa-mcp` under a sandbox profile when shipping

On macOS, ship a Sandbox profile (`sandbox-exec` rules) alongside the
binary that forbids:
- All network access (`(deny network*)`)
- Writes outside `$HOME/Library/Caches/swa-mcp` and the codebase path
- Process spawn (`(deny process-fork)`)

This eliminates the "what if some future commit calls `Process` from
the MCP code path" class of regression entirely.

---

## Things the project already got right

The recent hardening commits are real and well-executed. To call them
out honestly:

1. **Path canonicalisation in `CodebaseContext.validatePath` is
   correct.** Symlink resolution via `resolvingSymlinksInPath()`,
   `standardizedFileURL` for alias normalisation, separator-aware
   prefix check (`canonical == root || canonical.hasPrefix(root + "/")`)
   to close the `/tmp/codebase-secret` vs `/tmp/codebase` bypass.
   This is the correct shape and matches the threat-model the
   commit message claimed to address.

2. **`findSwiftFiles` re-canonicalises every enumerated file** and
   re-checks against the root (`CodebaseContext.swift:143-144`).
   `FileManager.enumerator` follows symlinks by default; this is the
   exact right way to prevent
   `Sources/normal.swift -> /etc/passwd` from leaking host files.

3. **`validateForReadFile` is shared between `handleReadFile` and the
   `ReadResource` handler.** That centralisation is the single most
   important security pattern in the file and is correctly done.
   Future hardening (e.g. content-type sniffing) lives in one place.
   No drift possible. (SWAMCPServer.swift:718-745, 1136-1144).

4. **Environment scrubbing in `ProcessExecutor.scrubbedEnvironment`
   uses an allowlist, not a denylist.** That's the only correct shape.
   The dropped variables (`DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`,
   `LD_PRELOAD`, `LD_LIBRARY_PATH`, `DEVELOPER_DIR`,
   `SWIFTPM_HOOKS_DIR`, `BASH_ENV`, `SHELL`) cover every dynamic-loader
   and shell-init injection vector. (ProcessExecutor.swift:31-34).

5. **`MemoryMappedFile.openFlags` includes `O_NOFOLLOW` on Darwin.**
   Belt-and-braces — the sandbox layer already rejects sibling
   symlinks, but `O_NOFOLLOW` guarantees the final path component is
   not a symlink regardless of caller. (MemoryMappedFile.swift:62-72).

6. **`MemoryMappedFile.init` does the regular-file check via
   `fstat`/`S_IFREG`, not via `attributesOfItem` (which would re-stat
   by path and reopen a TOCTOU window).** Using the file descriptor's
   own `fstat` after `open` is the canonical fix.
   (MemoryMappedFile.swift:97-108).

7. **`search_symbols` has a four-layer ReDoS defence**: query-length
   cap (256), static antipattern prefilter, name-length cap (1024
   bytes), 2.5 s wall-clock deadline. All four are necessary, none
   is sufficient. (SWAMCPServer.swift:813-839, 898-916). This is the
   right level of paranoia for an LLM-driven regex input.

8. **`search_symbols` returns partial results on budget exhaustion
   with an explicit warning** rather than failing closed.
   (SWAMCPServer.swift:958-961). Correct UX for a defensive tool —
   the LLM sees that results are incomplete and can re-issue a
   tightened query.

9. **`read_file` line-range validation is explicit and pre-checked
   before slicing.** The previous bug ("`lines[start..<end]` even if
   `endLine < startLine` hit a Swift precondition crash") is called
   out in the comment and the new code rejects the malformed range
   with an explicit error before the slice. (SWAMCPServer.swift:768-799).

10. **Stdlib `Synchronization.Mutex` and `Synchronization.Atomic` are
    used throughout** — `MemoryMappedFile.lineRangesLock`,
    `RegexCache.storage`, `AtomicBitmap.AtomicWord`. The decision to
    drop `swift-atomics` in 0.2.0 in favour of stdlib primitives is
    the right call, both for security (smaller surface) and for
    interop with Swift 6 strict concurrency.

11. **`@unchecked Sendable` / `nonisolated(unsafe)` discipline is
    excellent.** Every use has a doc comment explaining why it's
    sound. No drive-by `nonisolated(unsafe)` to suppress a warning.

12. **`SwiftFileParser` cache is bounded and LRU.** This was called
    out as a ship-blocker in the doc comment, and the
    `OrderedDictionary` choice is correct. (SwiftFileParser.swift:148-168).

13. **No network calls anywhere.** Verified by grep; consistent with
    `SECURITY.md`'s claim. The MCP transport is stdio only.

14. **No reflection-based deserialisation.** All `Codable` types are
    plain structs with non-`Any` fields. No `NSKeyedUnarchiver` or
    similar legacy gunk that has historically been a source of
    deserialization exploits on Apple platforms.

15. **`SECURITY.md` is honest about the `auto_build` limitation.** The
    note at lines 92-99 is exactly right: SPM treats `Package.swift`
    as Swift source at parse time, so building an untrusted project
    is equivalent to executing arbitrary Swift. The mitigation —
    don't expose `auto_build` over MCP, restrict to CLI invocations
    against trusted codebases — is the correct trade-off and the
    code matches the policy (`autoBuild` is not in the MCP tool
    schema; verified by `grep autoBuild Sources/SwiftStaticAnalysisMCP`
    returning no matches).

---

## Quick remediation checklist

Critical: none.

High:
- [ ] `handleDetectUnusedCode`: validate `args["index_store_path"]`
      via `context.validatePath` (HIGH-1).
- [ ] `ReadResource` handler: parse `uri` via `URL(string:)` and
      reject non-empty hosts; use `parsed.path` (HIGH-2).
- [ ] Bound `SWAMCPServer.contextCache` with an LRU policy and a
      sane default limit (HIGH-3).
- [ ] Centralise ReDoS guards in `RegexCache` / a `ValidatedRegex`
      helper; apply to `matchesGlobPattern` and any other
      user-input regex compilation (HIGH-4).

Medium:
- [ ] Scrub `Process.environment` in `StaticAnalysisCommandPlugin`
      explicitly (MEDIUM-1).
- [ ] Document the `read_file` extension allowlist and consider
      dropping `.plist`; add an optional `--deny-pattern` flag
      (MEDIUM-2).
- [ ] Route MCP `read_file` / `analyze_file` through `read()`/`pread()`,
      not `mmap`, to avoid SIGBUS on truncation (MEDIUM-3).
- [ ] `getCodebaseInfo`: stream files instead of fully reading them
      (MEDIUM-4).

Low:
- [ ] Apply `limit` inside `findSwiftFiles` (LOW-1).
- [ ] Enforce `--frozen` in CI; document `Package.resolved` rule
      (LOW-2, LOW-5).
- [ ] Cap stdout/stderr in `ProcessExecutor` (LOW-3).
- [ ] Switch `RegexCache` to `OrderedDictionary` for actual LRU
      (LOW-4).

Defense in depth:
- [ ] Per-tool capability flags at server start.
- [ ] Audit-log tool invocations to stderr.
- [ ] Trust-boundary doc comment at top of `SWAMCPServer.swift`.
- [ ] Property-based / fuzz tests for `validatePath` and
      `matchesGlobPattern`.
- [ ] SIGTERM/SIGINT handler that actually cancels the parked task.
- [ ] `.exact("0.12.1")` pin for the MCP SDK.
- [ ] `sandbox-exec` profile for the shipped binary.

---

## References

- Project files audited (all paths absolute):
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Package.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Package.resolved
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/SECURITY.md
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisMCP/SWAMCPServer.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisMCP/CodebaseContext.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/swa-mcp/main.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Memory/MemoryMappedFile.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Memory/SourceFileReader.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Utilities/ProcessExecutor.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Utilities/PathUtilities.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Utilities/RegexCache.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Parsing/SwiftFileParser.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SwiftStaticAnalysisCore/Concurrency/Bitmap.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/Filters/UnusedCodeFilter.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/IndexStore/IndexStoreReader.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/UnusedCodeDetector/IndexStore/IndexStoreFallback.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/StaticAnalysisCommandPlugin/Plugin.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SymbolLookup/Resolution/IndexStoreResolver.swift
  - /Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Sources/SymbolLookup/Resolution/SyntaxResolver.swift

- CWE references inline; OWASP "MCP Top 10" (in development) and
  Anthropic's MCP security guidance both flag the categories above —
  primarily insufficient input validation at the tool boundary,
  caching without limits, and trust placed in `URI`-shaped strings.
