# Getting Started

Learn how to install and run your first static analysis.

## Overview

SwiftStaticAnalysis can be used either as a command-line tool (`swa`) or as a Swift package dependency. This guide covers both approaches.

## Installation

### Pre-built Binary (Recommended)

Download the latest release:

```bash
# Universal binary (Apple Silicon + Intel)
curl -L https://github.com/g-cqd/SwiftStaticAnalysis/releases/latest/download/swa-macos-universal.tar.gz | tar xz
sudo mv swa /usr/local/bin/
```

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/g-cqd/SwiftStaticAnalysis.git", from: "0.0.13")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SwiftStaticAnalysis", package: "SwiftStaticAnalysis"),
    ]
)
```

This gives you access to all components. Alternatively, import individual modules:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SwiftStaticAnalysisCore", package: "SwiftStaticAnalysis"),  // Core only
        .product(name: "DuplicationDetector", package: "SwiftStaticAnalysis"),      // Clone detection
        .product(name: "UnusedCodeDetector", package: "SwiftStaticAnalysis"),       // Unused code
    ]
)
```

### Build from Source

```bash
git clone https://github.com/g-cqd/SwiftStaticAnalysis.git
cd SwiftStaticAnalysis
swift build -c release
cp .build/release/swa /usr/local/bin/
```

## Your First Analysis

### Using the CLI

Run a full analysis on your project:

```bash
# Full analysis (duplicates + unused code)
swa analyze /path/to/your/project

# Just detect duplicates
swa duplicates /path/to/your/project

# Just detect unused code
swa unused /path/to/your/project
```

### Understanding the Output

By default, `swa` outputs in Xcode-compatible format:

```
/path/to/file.swift:42:5: warning: Consider removing unused function 'unusedHelper'
/path/to/file.swift:100:1: warning: Duplicate code detected (exact clone, 2 occurrences)
```

For different output formats:

```bash
# Human-readable text
swa analyze . --format text

# JSON for programmatic processing
swa analyze . --format json > report.json
```

### Using the API

```swift
import SwiftStaticAnalysis

// Find all Swift files
let files = try findSwiftFiles(in: "/path/to/project")

// Detect duplicates
let dupDetector = DuplicationDetector()
let clones = try await dupDetector.detectClones(in: files)

for group in clones {
    print("Found \(group.type.rawValue) clone with \(group.occurrences) occurrences")
}

// Detect unused code
let unusedDetector = UnusedCodeDetector()
let unused = try await unusedDetector.detectUnused(in: files)

for item in unused {
    print("[\(item.confidence)] \(item.suggestion)")
}
```

## Multiple Paths

Analyze multiple directories or files in a single run:

```bash
swa analyze Sources/ Tests/Fixtures/

swa unused path/to/ModuleA path/to/ModuleB

swa duplicates Sources/Core Sources/Features
```

## Reducing False Positives

Use the `--sensible-defaults` flag to automatically exclude common false positives:

```bash
swa unused . --sensible-defaults
```

This excludes:
- Import statements
- Deinit methods
- Backticked enum cases (Swift keywords used as identifiers)

You can also exclude specific paths:

```bash
swa unused . --exclude-paths "**/Tests/**" --exclude-paths "**/Fixtures/**"
```

## Configuration File

Create a `.swa.json` file for persistent configuration. Only include the settings you want to customize:

```json
{
  "unused": {
    "sensibleDefaults": true
  }
}
```

A minimal configuration file for duplication detection:

```json
{
  "duplicates": {
    "minTokens": 100
  }
}
```

The `version` field is optional and defaults to `1` when not specified. See <doc:CLIReference> for the full configuration schema.

## Next Steps

- <doc:CloneDetection> - Learn about clone detection algorithms and configuration
- <doc:UnusedCodeDetection> - Understand detection modes and accuracy trade-offs
- <doc:IgnoreDirectives> - Suppress false positives directly in your source code
- <doc:CIIntegration> - Set up automated analysis in your CI pipeline
