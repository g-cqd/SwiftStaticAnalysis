# Clone Detection

Understand the different types of code clones and how to detect them.

## Overview

Code duplication is a common quality issue that increases maintenance burden and bug risk. SwiftStaticAnalysis detects three types of clones using specialized algorithms.

## Clone Types

### Type-1: Exact Clones

Identical code fragments, ignoring whitespace and comments.

**Algorithm**: Suffix Array with SA-IS construction (O(n) time complexity)

```bash
swa duplicates . --types exact
```

**Example**:
```swift
// Original
func calculateTotal(items: [Item]) -> Double {
    items.reduce(0) { $0 + $1.price }
}

// Exact clone (whitespace differences ignored)
func calculateTotal(items: [Item]) -> Double {
    items.reduce(0) { $0 + $1.price }
}
```

### Type-2: Near Clones

Code with renamed identifiers or different literals.

**Algorithm**: MinHash with Locality-Sensitive Hashing (LSH)

```bash
swa duplicates . --types near
```

**Example**:
```swift
// Original
func fetchUsers(page: Int) async throws -> [User] {
    let url = URL(string: "https://api.example.com/users?page=\(page)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode([User].self, from: data)
}

// Near clone (renamed identifiers, different URL)
func fetchProducts(page: Int) async throws -> [Product] {
    let url = URL(string: "https://api.example.com/products?page=\(page)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode([Product].self, from: data)
}
```

### Type-3/4: Semantic Clones

Functionally equivalent code with structural differences.

**Algorithm**: AST Fingerprinting with tree similarity matching

```bash
swa duplicates . --types semantic
```

**Example**:
```swift
// Original (for loop)
func sum(numbers: [Int]) -> Int {
    var total = 0
    for n in numbers {
        total += n
    }
    return total
}

// Semantic clone (reduce)
func sum(numbers: [Int]) -> Int {
    numbers.reduce(0, +)
}
```

## Configuration

### Minimum Token Threshold

Control the minimum size of detected clones:

```bash
# Detect smaller clones (more results, more noise)
swa duplicates . --min-tokens 20

# Detect larger clones only (fewer results, higher quality)
swa duplicates . --min-tokens 100
```

The default is 50 tokens, which typically corresponds to 5-10 lines of code.

### Combining Clone Types

Detect multiple clone types simultaneously:

```bash
swa duplicates . --types exact --types near --types semantic
```

### Programmatic Configuration

```swift
import SwiftStaticAnalysis

let config = DuplicationConfiguration(
    minimumTokens: 50,
    cloneTypes: [.exact, .near, .semantic],
    minimumSimilarity: 0.8  // For near/semantic clones
)

let detector = DuplicationDetector(configuration: config)
let clones = try await detector.detectClones(in: swiftFiles)
```

## Algorithm Details

### Suffix Array (Exact Clones)

The SA-IS (Suffix Array by Induced Sorting) algorithm constructs a suffix array in linear time. Longest Common Prefix (LCP) arrays identify repeated substrings efficiently.

**Advantages**:
- O(n) construction time
- Guaranteed to find all exact duplicates
- Memory-efficient for large codebases

### MinHash + LSH (Near Clones)

MinHash generates compact signatures that preserve Jaccard similarity. LSH enables sub-linear query time for finding similar code.

**Advantages**:
- Probabilistic but highly accurate
- Scales to millions of code fragments
- Configurable similarity threshold

### AST Fingerprinting (Semantic Clones)

Creates structural fingerprints from the Abstract Syntax Tree, ignoring surface-level syntax differences.

**Advantages**:
- Detects functionally equivalent code
- Language-aware analysis
- Catches refactoring opportunities

## Best Practices

1. **Start with exact clones** - They're the most reliable and easiest to refactor
2. **Adjust `--min-tokens`** - Lower for thorough analysis, higher to reduce noise
3. **Review near clones carefully** - Some may be intentionally similar (e.g., test fixtures)
4. **Use semantic detection sparingly** - Higher false positive rate but catches deep issues

## See Also

- <doc:UnusedCodeDetection>
- <doc:PerformanceOptimization>
