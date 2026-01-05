# Performance Optimization

Optimize analysis performance for large codebases.

## Overview

SwiftStaticAnalysis is designed to handle large Swift codebases efficiently. This guide covers the built-in optimizations and how to tune performance for your specific needs.

## Built-in Optimizations

### Memory-Mapped I/O

Files are memory-mapped rather than read entirely into memory, reducing allocation overhead for large files.

**Benefit**: Near-zero memory overhead for file reading, OS-managed caching.

### SoA Token Storage

Tokens are stored in a Struct-of-Arrays (SoA) layout rather than Array-of-Structs (AoS):

```swift
// Traditional AoS (poor cache locality)
struct Token { var kind: Kind; var offset: Int; var length: Int }
var tokens: [Token]

// SoA layout (excellent cache locality)
struct TokenStorage {
    var kinds: [Kind]
    var offsets: [Int]
    var lengths: [Int]
}
```

**Benefit**: 2-3x faster iteration for algorithms that scan specific token properties.

### Arena Allocation

Temporary data structures use arena allocation to reduce memory fragmentation:

**Benefit**: Faster allocation, batch deallocation, reduced GC pressure.

### Parallel Processing

File parsing is parallelized using Swift Concurrency:

```swift
// Internal implementation uses task groups
let results = await withTaskGroup(of: ParseResult.self) { group in
    for file in files {
        group.addTask { await parse(file) }
    }
    return await group.reduce(into: []) { $0.append($1) }
}
```

**Benefit**: Near-linear scaling with CPU cores.

Parallel processing also powers reachability edge building and optional parallel BFS/clone detection via `--parallel-mode safe`. For large pipelines, `ParallelMode.maximum` exposes streaming/backpressure APIs.

### SIMD-Accelerated Hashing

MinHash signature computation uses SIMD instructions when available:

**Benefit**: 4-8x faster signature generation for near-clone detection.

## Performance Tuning

### Choose the Right Detection Mode

| Mode | Memory | CPU | Use When |
|------|--------|-----|----------|
| `simple` | Low | Low | Quick scans, CI validation |
| `reachability` | Medium | Medium | Comprehensive dead code analysis |
| `indexStore` | High | High | Maximum accuracy needed |

```bash
# For CI pipelines, use simple mode
swa unused . --mode simple

# For thorough analysis, use reachability
swa unused . --mode reachability
```

### Adjust Clone Detection Thresholds

Higher `--min-tokens` values reduce processing time:

```bash
# Fast scan (larger clones only)
swa duplicates . --min-tokens 100

# Thorough scan (more results)
swa duplicates . --min-tokens 30
```

### Use Path Exclusions

Exclude directories that don't need analysis:

```bash
swa analyze . \
    --exclude-paths "**/Tests/**" \
    --exclude-paths "**/Fixtures/**" \
    --exclude-paths "**/Generated/**" \
    --exclude-paths "**/.build/**"
```

### Limit Clone Types

Only detect the clone types you care about:

```bash
# Fastest: exact clones only
swa duplicates . --types exact

# Balanced: exact and near
swa duplicates . --types exact --types near
```

### Enable Parallel Graph Algorithms

```bash
# Parallel reachability traversal (large graphs)
swa unused . --mode reachability --parallel-mode safe

# Parallel MinHash/LSH pipeline (large codebases)
swa duplicates . --algorithm minHashLSH --parallel-mode safe
```

`--parallel` is deprecated and maps to `--parallel-mode safe`.

## Benchmarks

Typical performance on a 2023 MacBook Pro (M3 Max):

| Codebase Size | Simple Mode | Reachability | IndexStore |
|---------------|-------------|--------------|------------|
| 10K lines | 0.5s | 1s | 3s |
| 100K lines | 2s | 5s | 15s |
| 1M lines | 15s | 45s | 2m |

Clone detection (exact only):

| Codebase Size | Time | Memory |
|---------------|------|--------|
| 10K lines | 0.3s | 50MB |
| 100K lines | 1.5s | 200MB |
| 1M lines | 12s | 1.5GB |

## Programmatic Performance Control

### Configuring Concurrency

```swift
import SwiftStaticAnalysis

// Limit concurrent file parsing
let config = ConcurrencyConfiguration(
    maxConcurrentFiles: 8,  // Default: ProcessInfo.processInfo.activeProcessorCount
    maxConcurrentTasks: 16
)

let parser = SwiftFileParser(configuration: config)
```

### Streaming Results

For very large codebases, process results as they're generated:

```swift
import SwiftStaticAnalysis

let detector = UnusedCodeDetector()

// Stream results instead of collecting all
for try await item in detector.detectUnusedStream(in: files) {
    if item.confidence == .high {
        print(item.suggestion)
    }
}
```

Stream clone verification batches for memory-bounded pipelines:

```swift
let verifier = StreamingVerifier.forMaximumMode()
for await progress in verifier.verifyStreaming(candidatePairs, documentMap: docs) {
    handle(progress.batchResults)
}
```

Stream reachability edges as they are computed:

```swift
let extractor = DependencyExtractor()
for await edge in extractor.streamEdges(from: analysisResult) {
    handle(edge)
}
```

### Caching Analysis Results

For incremental analysis, cache results between runs:

```swift
import SwiftStaticAnalysis

let detector = IncrementalDuplicationDetector(
    cachePath: ".swa-cache"
)

// Only re-analyzes changed files
let clones = try await detector.detectClones(in: files)
```

## Memory Management

### For Large Codebases

If analyzing very large codebases (1M+ lines), consider:

1. **Increase heap size** if hitting memory limits
2. **Use incremental analysis** to process in batches
3. **Exclude generated code** which often has repetitive patterns

### Monitoring Memory Usage

```swift
import Foundation

func printMemoryUsage() {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if result == KERN_SUCCESS {
        print("Memory: \(info.resident_size / 1_000_000) MB")
    }
}
```

## CI Performance Tips

1. **Cache the index store** between CI runs for `indexStore` mode
2. **Use `simple` mode** for PR validation (fast feedback)
3. **Run thorough analysis** on main branch only (nightly builds)
4. **Parallelize** analysis of multiple modules

See <doc:CIIntegration> for detailed CI setup.

## See Also

- <doc:CIIntegration>
- <doc:CloneDetection>
- <doc:UnusedCodeDetection>
