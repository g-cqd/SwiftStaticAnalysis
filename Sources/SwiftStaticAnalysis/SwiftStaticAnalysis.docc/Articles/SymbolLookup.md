# Symbol Lookup

Find and resolve symbols in Swift codebases using flexible query patterns.

## Overview

The SymbolLookup module provides powerful capabilities for finding symbols (classes, functions, properties, etc.) in Swift source files. It supports multiple query patterns and can resolve symbols using either IndexStore (fast) or syntax analysis (accurate).

## Basic Usage

```swift
import SwiftStaticAnalysis

// Create a symbol finder for your project
let finder = SymbolFinder(projectPath: "/path/to/project")

// Find symbols by name
let query = SymbolQuery.name("NetworkManager")
let matches = try await finder.find(query)

for match in matches {
    print("\(match.kind) \(match.name) at \(match.file):\(match.line)")
}
```

## Query Patterns

SymbolLookup supports five query pattern types:

### Simple Name

Find symbols by their base name:

```swift
let query = SymbolQuery.name("NetworkManager")
let matches = try await finder.find(query)
```

### Qualified Name

Find members within a specific type:

```swift
let query = SymbolQuery.qualifiedName("APIClient", "shared")
let matches = try await finder.find(query)

// Also works with deeper nesting
let nested = SymbolQuery.qualifiedName("Outer", "Inner", "method")
```

### Selector

Find methods by their signature (parameter labels):

```swift
// Find fetch(id:completion:)
let query = SymbolQuery.selector("fetch", labels: ["id", "completion"])
let matches = try await finder.find(query)

// Underscore represents unlabeled parameters
let query2 = SymbolQuery.selector("process", labels: [nil, "options"])
```

### USR (Unified Symbol Resolution)

Find symbols by their compiler-generated USR:

```swift
let query = SymbolQuery.usr("s:14NetworkMonitor6sharedACvpZ")
let matches = try await finder.find(query)
```

### Regex

Find symbols matching a regular expression:

```swift
let query = SymbolQuery.regex(try Regex("^handle.*Event$"))
let matches = try await finder.find(query)
```

## Filtering Results

Apply filters to narrow down results:

```swift
var query = SymbolQuery.name("shared")

// Filter by declaration kind
query.kindFilter = [.variable, .property]

// Filter by access level
query.accessFilter = [.public, .open]

// Limit to a specific containing type
query.scopeFilter = "NetworkManager"

// Limit number of results
query.limit = 10

let matches = try await finder.find(query)
```

## Finding Usages

Track where symbols are referenced:

```swift
let query = SymbolQuery.qualifiedName("Cache", "shared")
let matches = try await finder.find(query)

if let match = matches.first {
    let usages = try await finder.findUsages(of: match)

    for usage in usages {
        print("\(usage.kind): \(usage.file):\(usage.line):\(usage.column)")
    }
}
```

## CLI Usage

The `swa symbol` command provides CLI access to symbol lookup:

```bash
# Find by simple name
swa symbol NetworkManager Sources/

# Find by qualified name
swa symbol "APIClient.shared" Sources/

# Find by selector
swa symbol "fetch(id:completion:)" Sources/

# Filter by kind
swa symbol shared --kind variable --kind property Sources/

# Filter by access level
swa symbol Manager --access public Sources/

# Show only definitions
swa symbol NetworkManager --definition Sources/

# Show usages
swa symbol "Cache.shared" --usages Sources/

# Output as JSON
swa symbol NetworkManager --format json Sources/
```

## Resolution Strategies

SymbolLookup uses two resolution strategies:

### IndexStore Resolution

Uses the compiler's IndexStore database for fast lookups:

- **Pros**: Very fast, cross-module support
- **Cons**: Requires prior build, may be stale

```swift
let finder = try SymbolFinder(
    indexStorePath: ".build/debug/index/store",
    configuration: .init(useSyntaxFallback: true)
)
```

### Syntax Resolution

Parses source files directly using SwiftSyntax:

- **Pros**: Always accurate, no build required
- **Cons**: Slower for large codebases

```swift
var config = SymbolFinder.Configuration.default
config.useSyntaxFallback = true
config.sourceFiles = swiftFiles

let finder = SymbolFinder(configuration: config)
```

## Best Practices

1. **Use qualified names for disambiguation**: When multiple symbols share the same name, use qualified names to find the specific one you need.

2. **Prefer IndexStore when available**: If you have a recent build, IndexStore provides the fastest results.

3. **Use selectors for method disambiguation**: When a type has overloaded methods, use selector patterns with parameter labels.

4. **Combine filters**: Use kind and access filters together to narrow results quickly.

5. **Cache the SymbolFinder**: Creating a SymbolFinder has overhead; reuse it for multiple queries.

## See Also

- ``CLIReference``
- ``UnusedCodeDetection``
