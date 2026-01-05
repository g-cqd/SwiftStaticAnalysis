# CI Integration

Set up automated static analysis in your CI/CD pipeline.

## Overview

Integrating SwiftStaticAnalysis into your CI pipeline helps catch code quality issues before they reach production. This guide covers setup for popular CI systems.

## GitHub Actions

### Basic Setup

Create `.github/workflows/static-analysis.yml`:

```yaml
name: Static Analysis

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  analyze:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Install swa
        run: |
          curl -L https://github.com/g-cqd/SwiftStaticAnalysis/releases/latest/download/swa-macos-universal.tar.gz | tar xz
          sudo mv swa /usr/local/bin/

      - name: Run Analysis
        run: swa analyze . --format text
```

### With Xcode Warnings

Output in Xcode format to see warnings in GitHub's code view:

```yaml
      - name: Run Analysis
        run: swa analyze . --format xcode
```

### JSON Report for Artifacts

Save detailed reports as artifacts:

```yaml
      - name: Run Analysis
        run: |
          swa analyze . --format json > analysis-report.json
          swa unused . --sensible-defaults --format text

      - name: Upload Report
        uses: actions/upload-artifact@v4
        with:
          name: analysis-report
          path: analysis-report.json
```

### Fail on Issues

Fail the build if issues are found:

```yaml
      - name: Run Analysis
        run: |
          # Capture output and exit code
          swa unused . --sensible-defaults --format text | tee unused.txt

          # Fail if any high-confidence issues found
          if grep -q "\[high\]" unused.txt; then
            echo "::error::High-confidence unused code detected"
            exit 1
          fi
```

### Cache Index Store

For faster `indexStore` mode analysis:

```yaml
      - name: Cache Index Store
        uses: actions/cache@v4
        with:
          path: .build/debug/index/store
          key: index-store-${{ hashFiles('**/*.swift') }}
          restore-keys: |
            index-store-

      - name: Build Project
        run: swift build

      - name: Run IndexStore Analysis
        run: swa unused . --mode indexStore --index-store-path .build/debug/index/store
```

## DocC Documentation

Generate DocC documentation in CI (same command used for GitHub Pages):

```bash
swift package --allow-writing-to-directory ./docs \
  generate-documentation \
  --target SwiftStaticAnalysis \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path SwiftStaticAnalysis \
  --output-path ./docs
```

## GitLab CI

Create `.gitlab-ci.yml`:

```yaml
stages:
  - analyze

static-analysis:
  stage: analyze
  image: swift:6.0
  before_script:
    - curl -L https://github.com/g-cqd/SwiftStaticAnalysis/releases/latest/download/swa-macos-universal.tar.gz | tar xz
    - mv swa /usr/local/bin/
  script:
    - swa analyze . --format text
  artifacts:
    reports:
      codequality: analysis-report.json
    paths:
      - analysis-report.json
```

## Bitrise

Add to your `bitrise.yml`:

```yaml
workflows:
  analyze:
    steps:
      - script:
          title: Install swa
          inputs:
            - content: |
                curl -L https://github.com/g-cqd/SwiftStaticAnalysis/releases/latest/download/swa-macos-universal.tar.gz | tar xz
                sudo mv swa /usr/local/bin/
      - script:
          title: Run Static Analysis
          inputs:
            - content: swa analyze . --format xcode
```

## Xcode Cloud

Add a custom build script `ci_scripts/ci_post_clone.sh`:

```bash
#!/bin/bash
set -e

# Install swa
curl -L https://github.com/g-cqd/SwiftStaticAnalysis/releases/latest/download/swa-macos-universal.tar.gz | tar xz
sudo mv swa /usr/local/bin/

# Run analysis
swa analyze . --format xcode
```

## Processing JSON Output

### Parsing Results

The JSON output structure:

```json
{
  "clones": [
    {
      "type": "exact",
      "occurrences": 2,
      "clones": [
        {"file": "path/to/file.swift", "startLine": 10, "endLine": 20},
        {"file": "path/to/other.swift", "startLine": 50, "endLine": 60}
      ]
    }
  ],
  "unused": [
    {
      "declaration": {
        "name": "unusedFunction",
        "kind": "function",
        "location": {"file": "...", "line": 42, "column": 5}
      },
      "reason": "noReferences",
      "confidence": "high",
      "suggestion": "Consider removing unused function 'unusedFunction'"
    }
  ]
}
```

### Shell Script Processing

```bash
#!/bin/bash

# Run analysis
swa analyze . --format json > report.json

# Count issues
CLONES=$(jq '.clones | length' report.json)
UNUSED=$(jq '.unused | length' report.json)
HIGH_CONF=$(jq '[.unused[] | select(.confidence == "high")] | length' report.json)

echo "Clone groups: $CLONES"
echo "Unused items: $UNUSED"
echo "High confidence: $HIGH_CONF"

# Fail if too many high-confidence issues
if [ "$HIGH_CONF" -gt 10 ]; then
    echo "Too many high-confidence unused code issues!"
    exit 1
fi
```

### Python Processing

```python
import json
import sys

with open('report.json') as f:
    report = json.load(f)

# Summarize by file
by_file = {}
for item in report['unused']:
    file = item['declaration']['location']['file']
    by_file.setdefault(file, []).append(item)

print("Issues by file:")
for file, items in sorted(by_file.items(), key=lambda x: -len(x[1])):
    high = sum(1 for i in items if i['confidence'] == 'high')
    print(f"  {file}: {len(items)} ({high} high)")
```

## Thresholds and Gates

### Recommended Thresholds

| Project Size | Max Clones | Max Unused (high) |
|--------------|------------|-------------------|
| Small (<10K lines) | 5 | 10 |
| Medium (10-100K) | 20 | 50 |
| Large (>100K) | 50 | 100 |

### Quality Gate Script

```bash
#!/bin/bash
set -e

MAX_CLONES=20
MAX_HIGH_UNUSED=50

swa analyze . --format json > report.json

CLONES=$(jq '.clones | length' report.json)
HIGH_UNUSED=$(jq '[.unused[] | select(.confidence == "high")] | length' report.json)

FAILED=0

if [ "$CLONES" -gt "$MAX_CLONES" ]; then
    echo "::error::Too many clone groups: $CLONES (max: $MAX_CLONES)"
    FAILED=1
fi

if [ "$HIGH_UNUSED" -gt "$MAX_HIGH_UNUSED" ]; then
    echo "::error::Too many high-confidence unused items: $HIGH_UNUSED (max: $MAX_HIGH_UNUSED)"
    FAILED=1
fi

exit $FAILED
```

## PR Comments

### GitHub Action with PR Comment

```yaml
      - name: Run Analysis
        id: analysis
        run: |
          swa analyze . --format json > report.json
          CLONES=$(jq '.clones | length' report.json)
          UNUSED=$(jq '.unused | length' report.json)
          echo "clones=$CLONES" >> $GITHUB_OUTPUT
          echo "unused=$UNUSED" >> $GITHUB_OUTPUT

      - name: Comment on PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const clones = '${{ steps.analysis.outputs.clones }}';
            const unused = '${{ steps.analysis.outputs.unused }}';
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `## Static Analysis Results\n\n- Clone groups: ${clones}\n- Unused items: ${unused}`
            });
```

## Best Practices

1. **Run on every PR** - Catch issues before merge
2. **Use sensible defaults** - Reduce noise with `--sensible-defaults`
3. **Cache aggressively** - Index store and build artifacts
4. **Set realistic thresholds** - Don't block all PRs initially
5. **Review periodically** - Adjust thresholds as codebase improves
6. **Archive reports** - Track trends over time

## See Also

- <doc:GettingStarted>
- <doc:PerformanceOptimization>
- <doc:IgnoreDirectives>
