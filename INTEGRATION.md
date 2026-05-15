# Integrating swa into your workflow

Three drop-in surfaces ship with SwiftStaticAnalysis:

- A **composite GitHub Action** (`action.yml`) that builds `swa` from source and runs unused-code + duplication detection, optionally emitting SARIF for code-scanning integrations.
- A **pre-commit-framework manifest** (`.pre-commit-hooks.yaml`) exposing `swa-analyze`, `swa-duplicates`, and `swa-unused` hooks.
- The raw `swa` CLI for **local dev** and **custom CI**.

This document covers all three.

## GitHub Actions

### Minimal workflow

Drop into `.github/workflows/swa.yml`:

```yaml
name: swa
on: [push, pull_request]
jobs:
  swa:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: swift-actions/setup-swift@v2
        with:
          swift-version: '6.2'
      - uses: g-cqd/SwiftStaticAnalysis@main
        with:
          path: Sources
          mode: reachability
          clone-types: exact,near
          min-tokens: '50'
          format: sarif
          fail-on: error
      - name: Upload SARIF to code scanning
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: ${{ steps.swa.outputs.sarif-path }}
```

The action exposes these inputs:

| input | default | values |
|---|---|---|
| `path` | `.` | any directory or file |
| `mode` | `reachability` | `reachability`, `simple`, `indexStore` |
| `clone-types` | `exact,near` | comma-separated subset of `exact`, `near`, `semantic` |
| `min-tokens` | `50` | integer |
| `format` | `sarif` | `sarif`, `text`, `json`, `xcode` |
| `fail-on` | `error` | `error`, `warning`, `never` |
| `swa-version` | `''` | optional ref (tag/branch/SHA) — defaults to current workspace |
| `working-directory` | `${{ github.workspace }}` | working dir override |

Outputs: `unused-count`, `duplicates-count`, `sarif-path`.

### SARIF + GitHub Code Scanning

When `format: sarif`, the action emits a SARIF v2.1.0 file and uploads it as an artifact (`swa-sarif`). Pair with `github/codeql-action/upload-sarif@v3` to surface findings on the **Security → Code scanning** tab of the repo.

The minimal SARIF includes:
- `ruleId`: `duplicate-<type>` or `unused-<kind>`
- `level: warning`
- `physicalLocation` with file, startLine, endLine.

It is not a substitute for a full SARIF run definition (no `tool.driver.rules`, no taxonomies) — it's a pragmatic floor for code-scanning ingest.

## pre-commit framework

Add this to a consumer repo's `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/g-cqd/SwiftStaticAnalysis
    rev: 0.3.0-beta.11
    hooks:
      - id: swa-analyze
      - id: swa-duplicates
      - id: swa-unused
```

`swa-analyze` runs per file (passes staged Swift files via `pass_filenames: true`).
`swa-duplicates` and `swa-unused` run across `Sources` (duplication and reachability are cross-file by construction).

### Prereq: `swa` on `$PATH`

These hooks use `language: system`, so the binary must already be installed. Two options:

**Option A — build from source once per machine:**

```bash
git clone https://github.com/g-cqd/SwiftStaticAnalysis ~/.local/share/SwiftStaticAnalysis
cd ~/.local/share/SwiftStaticAnalysis
swift build -c release --product swa
ln -s "$PWD/.build/release/swa" ~/.local/bin/swa
```

**Option B — Homebrew formula** (if/when published):

```bash
brew install g-cqd/tap/swa
```

## Local install

Direct CLI usage:

```bash
git clone https://github.com/g-cqd/SwiftStaticAnalysis
cd SwiftStaticAnalysis
swift build -c release
.build/release/swa --help
.build/release/swa analyze Sources
.build/release/swa duplicates Sources --types exact --types near
.build/release/swa unused Sources --mode reachability --sensible-defaults
```

The CLI honors a `.swa.json` configuration file in the analyzed directory. Schema is at `.swa.schema.json`.

## Custom CI without the composite action

If the composite action's input shape doesn't match your needs, invoke `swa` directly:

```yaml
- name: Build swa
  run: swift build -c release --product swa
- name: Run swa
  run: |
    .build/release/swa duplicates Sources \
      --types exact --types near \
      --min-tokens 50 \
      -f json > duplicates.json
    .build/release/swa unused Sources \
      --mode reachability --sensible-defaults \
      -f json > unused.json
```

JSON output is suitable for downstream tooling (Codacy, custom dashboards, mutation-test gates).

## See also

- `README.md` — feature overview.
- `SECURITY.md` — security model, sandboxing, and threat model for the MCP server.
- `.swa.schema.json` — configuration-file schema.
- `Sources/SwiftStaticAnalysis/SwiftStaticAnalysis.docc/` — full DocC documentation.
