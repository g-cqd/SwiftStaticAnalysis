# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1.0 | :x:                |

## Reporting a Vulnerability

**Please do not file public GitHub Issues for security reports.** Use GitHub's
[Private Vulnerability Reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
instead:

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Submit a private advisory describing the issue and reproduction steps.

For urgent / out-of-band reports, send the report to the maintainer's GitHub
profile email; mark the subject `[SECURITY] swiftstaticanalysis`.

We will:
- Acknowledge receipt within 48 hours.
- Provide an initial assessment within 7 days.
- Coordinate fix and disclosure timing with the reporter.

## Security Features

SwiftStaticAnalysis ships several defence-in-depth features. They reduce
risk; they are not a guarantee.

### MCP Sandbox

The `swa-mcp` server enforces a sandbox around a single codebase root:

- `CodebaseContext.validatePath` canonicalises both the candidate and the
  root via `URL.resolvingSymlinksInPath()` before applying a separator-aware
  prefix check (`canonical == root || canonical.hasPrefix(root + "/")`).
  This closes the sibling-path-prefix bypass and the symlink-escape attack
  that affected 0.1.4 and earlier.
- `findSwiftFiles` skips symbolic links whose canonical target falls
  outside the codebase root, so a hostile repository cannot expose
  arbitrary host files via `Sources/normal.swift -> /etc/passwd`.
- `handleReadFile` rejects non-regular files (FIFOs, devices, sockets),
  enforces a 10 MiB size cap, an extension allowlist, and validates the
  requested line range before slicing.
- `handleSearchSymbols` caps query length at 256 bytes, refuses
  nested-quantifier ReDoS antipatterns (`(.*)+`, `(a+)+`), compiles the
  regex once, and aborts after a 2.5 s wall-clock budget if matching is
  catastrophic.

### Memory Safety

- `MemoryMappedFile.init` calls `fstat` to verify the target is a regular
  file (rejects `/dev/zero`, FIFOs, etc.), caps mappings at 256 MiB, and
  uses `O_NOFOLLOW` on Darwin.
- All Swift code is built under Swift 6 strict concurrency and language
  mode `v6`. Synchronisation primitives are the stdlib
  `Synchronization.Mutex` and `Synchronization.Atomic` (no manual
  `NSLock`).

### No Network Connectivity

The analyzer does not make outbound network calls. The MCP server
communicates over stdio only; it does not bind a network socket.

### No Telemetry

No analytics, telemetry, or remote logging. All processing happens
locally.

### Subprocess Environment Scrubbing

`swa unused --auto-build` (and the `xcrun --find swift` toolchain
discovery) shells out via `ProcessExecutor`. The child receives **only**
the following allowlisted environment variables:

`PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`,
`LC_MESSAGES`, `TMPDIR`, `TERM`.

Everything else — including `DYLD_INSERT_LIBRARIES`,
`DYLD_LIBRARY_PATH`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, `DEVELOPER_DIR`,
`SWIFTPM_HOOKS_DIR`, `BASH_ENV`, `SHELL` — is dropped before
`Process.run()`. This prevents environment-based code injection into
the toolchain.

The SPM plugin host (`StaticAnalysisCommandPlugin`) is sandbox-locked
to `PackagePlugin + Foundation` and cannot use `ProcessExecutor`; its
two `Process` invocations remain in-place.

## Known Limitations

- **`swa unused --auto-build` invokes `swift build`** in the analysed
  codebase. SPM interprets `Package.swift` as Swift source code at
  parse time, so building an untrusted project is equivalent to
  executing its `Package.swift`. The `auto_build` flag is NOT exposed
  via the MCP tool surface; CLI invocations against untrusted
  codebases should not pass `--auto-build`.

## Best Practices

When using SwiftStaticAnalysis:

1. **Review output** before taking automated actions on remediation
   suggestions.
2. **Pin the version** in `Package.resolved`; SwiftStaticAnalysis pulls
   in `indexstore-db` by revision and `mattt/eventsource` transitively.
3. **Do not enable `--auto-build`** on untrusted codebases.
4. **Keep updated** to receive security fixes.
