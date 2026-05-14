# Security

What the MCP server guarantees against a hostile codebase, what it
doesn't, and where the boundaries are.

## Overview

The MCP server (`SWAMCPServer`) is the only external attack surface in
the package. The CLI (`swa`) and library APIs run with the user's full
local trust; their inputs are the user's own commands. The MCP server
runs with whatever trust an AI assistant brings to it — meaning every
tool argument originates from untrusted JSON.

This article documents the sandbox boundary, the input validation
applied to each MCP tool, and the residual risks.

## Reporting a vulnerability

See `SECURITY.md` at the repository root for the disclosure process.
Use GitHub's Private Vulnerability Reporting; do **not** file a public
issue.

## The codebase sandbox

`CodebaseContext.validatePath(_:)` is the single chokepoint for any
filesystem operation derived from MCP input. It performs:

1. Tilde expansion via `PathUtilities.expandingTildeInPath`.
2. Absolute-vs-relative resolution against the codebase root.
3. Symlink resolution via `URL.resolvingSymlinksInPath()`.
4. Path canonicalisation via `URL.standardizedFileURL`.
5. Separator-aware prefix check:
   `canonical == rootPath || canonical.hasPrefix(rootPath + "/")`.

This closes two pre-0.2.0 vulnerabilities:

- **Sibling-path bypass.** `hasPrefix(rootPath)` without the trailing
  separator accepted `/tmp/codebase-secret/...` for a root of
  `/tmp/codebase`. The separator-aware check rejects it.
- **Symlink escape.** A file inside the codebase that's a symlink to
  `/etc/passwd` previously slipped through. `resolvingSymlinksInPath()`
  resolves the chain; the canonical target is re-checked against the
  canonical root.

`CodebaseContext.findSwiftFiles(excludePatterns:)` re-applies the same
canonical-prefix check to each enumerated URL, so a hostile repository
shipping `Sources/normal.swift -> /Users/user/.aws/credentials` is
filtered out of the discovered file list.

## File reads

The `read_file` MCP tool and the `ReadResource` handler share a single
guard (`SWAMCPServer.validateForReadFile(path:validatedPath:)`):

- Extension allow-list: `.swift`, `.md`, `.json`, `.yml`, `.yaml`,
  `.txt`, `.toml`, `.plist`. Everything else is rejected.
- `FileManager.attributesOfItem(atPath:)[.type]` must equal
  `.typeRegular`. FIFOs, character devices (`/dev/zero`,
  `/dev/random`), block devices, sockets, and directories are
  rejected.
- 10 MiB size cap.
- Line range (`start_line`, `end_line`) is validated *before* slicing
  so an inverted range cannot trigger a precondition crash.

`MemoryMappedFile.init(path:)` enforces the regular-file check itself
(via `fstat` and `S_IFREG`), caps mappings at 256 MiB by default, and
uses `O_NOFOLLOW` on Darwin so a symlink swap between
`validatePath` and `open` cannot redirect the read.

## Regex search

`search_symbols` with `use_regex=true` is the only tool that accepts
user-supplied regex. The hardening is:

- Query length cap of 256 bytes.
- Static pre-filter rejecting nested-quantifier antipatterns:
  `(...*)+`, `(...+)+`, `(.*)+`, `(.*)*`, etc.
- Per-symbol input length cap of 1024 bytes — catastrophic backtracking
  scales polynomially with input length, so this bounds the per-match
  cost even when an antipattern slipped past the prefilter.
- Wall-clock evaluation budget of 2.5 s across *all* matches in a
  single call. Once exceeded, evaluation stops and the partial result
  set is returned with a warning.

## Subprocess environment scrubbing

`swa unused --auto-build` and the `xcrun --find swift` toolchain
discovery shell out via `ProcessExecutor`. The child receives **only**
the following allow-listed environment variables: `PATH`, `HOME`,
`USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LC_MESSAGES`,
`TMPDIR`, `TERM`.

Everything else is dropped before `Process.run()`, including
`DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `LD_PRELOAD`,
`LD_LIBRARY_PATH`, `DEVELOPER_DIR`, `SWIFTPM_HOOKS_DIR`, `BASH_ENV`,
`SHELL`. This prevents environment-based code injection into the
toolchain.

The SPM plugin host (`StaticAnalysisCommandPlugin`) is sandbox-locked
to `PackagePlugin + Foundation` and cannot use `ProcessExecutor`; its
two `Process` invocations remain in-place. Plugin trust is controlled
by Xcode / SPM, not by us.

## Residual risks

- **`swa unused --auto-build` invokes `swift build`** in the analysed
  codebase. SPM interprets `Package.swift` as Swift source code at
  parse time, so building an untrusted project is equivalent to
  executing its `Package.swift`. The `auto_build` flag is NOT exposed
  via the MCP tool surface; CLI invocations against untrusted
  codebases should not pass `--auto-build`.
- **Transitive dependency pinning**. `indexstore-db` is pinned by
  revision because the upstream package does not tag releases. The
  `swift-lmdb` subdep tracks `main`. SwiftPM does not verify upstream
  signatures; a malicious force-push to either of these would
  propagate. `Package.resolved` locks the specific commit hash; review
  it on `swift package update`.
- **The MCP server runs in-process.** A bug in any dependency
  (`swift-syntax`, `indexstore-db`, `swift-sdk`) is reachable from
  hostile MCP input. The MCP transport is stdio-only; there is no
  network attack surface.

## Test coverage

Security regressions are covered by:

- `Tests/SwiftStaticAnalysisMCPTests/CodebaseContextTests.swift`:
  sibling-path bypass, symlink escape, glob metacharacter escaping,
  tilde handling, `findSwiftFiles` symlink filtering.
- `Tests/SwiftStaticAnalysisCoreTests/ProcessExecutorTests.swift`:
  environment scrubbing (`DYLD_*`, `DEVELOPER_DIR`, `SWIFTPM_HOOKS_DIR`,
  `LD_*`, `SHELL`, `BASH_ENV` dropped); live `/bin/sh -c env` round
  trip; caller overrides shadow inherited values.
