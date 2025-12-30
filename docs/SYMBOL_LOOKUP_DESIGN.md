# Symbol Lookup Feature - Research & Design Document

## Overview

This document presents research on state-of-the-art symbol lookup techniques and proposes an implementation for SwiftStaticAnalysis that enables searching for symbols like `NetworkMonitor.shared` via CLI.

---

## Part 1: Language-Agnostic Research

### 1.1 Core Concepts in Symbol Lookup

#### What is a Symbol?

A **symbol** is any named entity in source code: functions, classes, variables, properties, types, modules, etc. Symbol lookup systems must:

1. **Index** - Collect and store symbol information
2. **Query** - Find symbols matching search criteria
3. **Resolve** - Determine exact locations and relationships

#### Symbol Identification Challenges

| Challenge | Description |
|-----------|-------------|
| **Ambiguity** | Same name in different scopes (e.g., `User.id` vs `Product.id`) |
| **Qualified Names** | Dot-notation like `NetworkMonitor.shared` |
| **Cross-module** | Symbols defined in external modules/packages |
| **Dynamic Dispatch** | Protocol witnesses, overrides |
| **Generics** | Type parameters and specializations |

### 1.2 Indexing Approaches

#### 1.2.1 Trigram Indexes (Google Code Search / Zoekt)

Used by [Google Code Search](https://swtch.com/~rsc/regexp/regexp4.html) and [Sourcegraph's Zoekt](https://github.com/sourcegraph/zoekt).

**How it works:**
- Split text into overlapping 3-character sequences ("trigrams")
- Build inverted index: `trigram → [file_locations]`
- Query: intersect posting lists for all trigrams in search term

**Example:** Searching for `shared` produces trigrams: `sha`, `har`, `are`, `red`

```
Index:
  "sha" → [file1:100, file2:200, file3:50]
  "har" → [file1:101, file2:201]
  "are" → [file1:102, file3:51]
  "red" → [file1:103, file2:202]

Query result: intersect → file1 (contains all trigrams)
```

**Pros:**
- Supports substring and regex search
- Language-agnostic
- Scales to billions of lines (GitHub, Sourcegraph)

**Cons:**
- No semantic understanding
- False positives require post-filtering
- Doesn't understand symbol relationships

**Source:** [Trigram-Based Persistent IDE Indices (2024)](https://arxiv.org/html/2403.03751v1)

#### 1.2.2 AST-Based Indexing

Parse source into Abstract Syntax Tree, extract symbols with full context.

**Example (conceptual):**
```
class NetworkMonitor {
    static let shared = NetworkMonitor()
}
```

Produces structured index:
```json
{
  "symbol": "shared",
  "kind": "staticProperty",
  "type": "NetworkMonitor",
  "parent": "NetworkMonitor",
  "qualifiedName": "NetworkMonitor.shared",
  "accessLevel": "internal",
  "location": {"file": "NetworkMonitor.swift", "line": 2, "column": 16}
}
```

**Pros:**
- Full semantic context
- Understands scope and relationships
- Supports type-aware queries

**Cons:**
- Language-specific parsers required
- Slower to build index
- Must re-index on changes

#### 1.2.3 Compiler-Generated Indexes

Modern compilers can emit index data during compilation.

**Examples:**
- **Clang/Swift**: `-index-store-path` flag generates index data
- **Rust**: `rust-analyzer` uses compiler internals
- **Go**: `gopls` uses compiler-level analysis

**Pros:**
- 100% accurate (matches what compiler sees)
- Includes cross-module information
- Resolves all types and overloads

**Cons:**
- Requires successful build
- Index can become stale
- Slower initial indexing

### 1.3 Query Architectures

#### 1.3.1 Language Server Protocol (LSP)

[LSP Specification 3.17](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/) defines standard symbol queries:

| Request | Purpose |
|---------|---------|
| `textDocument/definition` | Go to definition |
| `textDocument/references` | Find all references |
| `textDocument/implementation` | Find implementations |
| `workspace/symbol` | Search symbols in workspace |
| `textDocument/documentSymbol` | Symbols in a file |

**Workspace Symbol Query:**
```json
{
  "query": "NetworkMonitor.shared",
  "kind": ["Property", "Variable"]
}
```

#### 1.3.2 Universal Ctags

[Universal Ctags](https://github.com/universal-ctags/ctags) generates tag files with symbol locations.

**Tags format:**
```
shared	NetworkMonitor.swift	/^    static let shared/;"	v	class:NetworkMonitor
```

**Note:** Swift is not natively supported; requires [custom regex definitions](https://akrabat.com/ctags-with-swift/).

#### 1.3.3 Tree-sitter Queries

[Tree-sitter](https://github.com/tree-sitter/tree-sitter) provides incremental parsing with S-expression queries:

```scheme
;; Find all static property declarations
(property_declaration
  (modifiers (static))
  (property_binding_pattern
    (property_identifier) @name))
```

**Swift API:** [swift-tree-sitter](https://github.com/tree-sitter/swift-tree-sitter)

### 1.4 Ranking & Relevance

Symbol search results need ranking. Common signals:

| Signal | Weight | Description |
|--------|--------|-------------|
| Exact match | High | `shared` matches `shared` exactly |
| Prefix match | Medium | `share` matches `shared` |
| Kind match | Medium | Searching for functions filters out variables |
| Scope proximity | Low | Symbols in same file/module ranked higher |
| Usage frequency | Low | More-referenced symbols ranked higher |

---

## Part 2: Swift-Specific Techniques

### 2.1 Unified Symbol Resolution (USR)

Swift/Clang use **USRs** as unique symbol identifiers across the entire codebase.

**Example USRs:**
```
s:14NetworkMonitor6sharedACvpZ     // NetworkMonitor.shared (static property)
s:14NetworkMonitorC                  // NetworkMonitor (class)
s:14NetworkMonitorC4initACycfc       // NetworkMonitor.init()
```

**USR Structure:**
- `s:` = Swift symbol
- `14NetworkMonitor` = length-prefixed name
- `C` = class kind
- `6shared` = property name
- `vp` = variable property
- `Z` = static

**Source:** [Swift Forums - USR](https://forums.swift.org/t/unified-symbol-resolution-giving-non-unique-resolution-of-variables/10812)

### 2.2 IndexStoreDB

[IndexStoreDB](https://github.com/swiftlang/indexstore-db) is Apple's official index library.

**Architecture:**
```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Swift/Clang    │────▶│   Index Store    │────▶│  IndexStoreDB   │
│   Compiler      │     │  (Raw Data)      │     │  (Query API)    │
└─────────────────┘     └──────────────────┘     └─────────────────┘
        │                       │                        │
  -index-store-path      .indexstore/              LMDB cache
```

**Key APIs:**
```swift
// Find by name
db.forEachCanonicalSymbolOccurrence(byName: "shared") { occurrence in
    // occurrence.symbol.usr, .name, .kind
    // occurrence.location.path, .line, .column
    // occurrence.roles (definition, reference, etc.)
}

// Find by USR
db.forEachSymbolOccurrence(byUSR: "s:14NetworkMonitor6sharedACvpZ", roles: .all) { ... }

// Find related (parent, children, protocol witnesses)
db.forEachRelatedSymbolOccurrence(byUSR: parentUSR, roles: .all) { ... }
```

**Symbol Roles (OptionSet):**
- `.declaration` - Forward declaration
- `.definition` - Full definition
- `.reference` - Usage/reference
- `.read` - Read access
- `.write` - Write/mutation
- `.call` - Function call
- `.dynamic` - Dynamic dispatch
- `.implicit` - Compiler-synthesized

### 2.3 SourceKit-LSP

[SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp) implements LSP for Swift.

**Symbol search flow:**
1. Parse workspace symbol query
2. Query IndexStoreDB for matching symbols
3. Use SourceKit for additional resolution (if needed)
4. Return LSP-formatted results

### 2.4 Qualified Name Resolution

For `NetworkMonitor.shared`:

**Approach 1: Parse and Query**
```swift
let components = "NetworkMonitor.shared".split(separator: ".")
// ["NetworkMonitor", "shared"]

// Find "NetworkMonitor" first
let containerMatches = index.find(name: "NetworkMonitor", kind: [.class, .struct, .actor, .enum])

// Then find "shared" within those containers
for container in containerMatches {
    let members = index.findMembers(of: container.usr, named: "shared")
}
```

**Approach 2: Direct USR Lookup**
```swift
// If user provides USR directly
db.forEachSymbolOccurrence(byUSR: userProvidedUSR, roles: .all) { ... }
```

**Approach 3: Fuzzy Matching**
```swift
// Search for both parts, intersect results by containment
let containerResults = search("NetworkMonitor")
let memberResults = search("shared")
let qualified = memberResults.filter { member in
    containerResults.any { container in
        member.isContainedIn(container)
    }
}
```

---

## Part 3: SwiftStaticAnalysis Implementation Proposal

### 3.1 Existing Infrastructure

SwiftStaticAnalysis already has:

| Component | Location | Capability |
|-----------|----------|------------|
| `IndexStoreReader` | `IndexStore/IndexStoreReader.swift` | IndexStoreDB wrapper |
| `DeclarationIndex` | `Models/Declaration.swift` | Name/kind/file/scope lookup |
| `ReferenceIndex` | `Models/Reference.swift` | Reference tracking |
| `IndexBasedDependencyGraph` | `IndexStore/` | Cross-module relationships |

### 3.2 Proposed CLI Interface

```bash
# Basic symbol search
swa symbol "NetworkMonitor.shared"
swa symbol "shared" --kind property

# Search with filters
swa symbol "shared" --kind staticProperty --in-type NetworkMonitor
swa symbol "ViewModel" --kind class --access public

# Find all usages
swa symbol "NetworkMonitor.shared" --usages

# Find definition only
swa symbol "NetworkMonitor.shared" --definition

# Output formats
swa symbol "shared" --format json
swa symbol "shared" --format xcode
```

### 3.3 Query Model

```swift
/// Symbol search query specification.
public struct SymbolQuery: Sendable {
    /// The search pattern (name or qualified name).
    let pattern: String

    /// Optional kind filter.
    let kinds: Set<SymbolKind>?

    /// Optional access level filter.
    let accessLevels: Set<AccessLevel>?

    /// Optional containing type filter.
    let containingType: String?

    /// Optional file path filter.
    let inFile: String?

    /// What to search for.
    let searchMode: SearchMode

    enum SearchMode {
        case definition      // Only definition location
        case usages          // Only usage locations
        case all             // Both definition and usages
    }
}
```

### 3.4 Result Model

```swift
/// Symbol search result.
public struct SymbolMatch: Sendable, Codable {
    /// Symbol name.
    let name: String

    /// Fully qualified name (e.g., "NetworkMonitor.shared").
    let qualifiedName: String

    /// Symbol kind.
    let kind: SymbolKind

    /// USR for precise identification.
    let usr: String?

    /// Access level.
    let accessLevel: AccessLevel

    /// Definition location.
    let definition: SourceLocation?

    /// All reference locations (if requested).
    let references: [SymbolReference]?

    /// Containing type (if member).
    let container: String?

    /// Module name.
    let module: String?
}

public struct SymbolReference: Sendable, Codable {
    let location: SourceLocation
    let context: ReferenceContext  // call, read, write, etc.
}
```

### 3.5 Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         CLI Layer                                │
│  swa symbol "NetworkMonitor.shared" --usages --format json      │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      SymbolLookup Module                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ QueryParser  │──│ SymbolFinder │──│ ResultFormatter      │   │
│  │              │  │              │  │ (text/json/xcode)    │   │
│  └──────────────┘  └──────┬───────┘  └──────────────────────┘   │
└─────────────────────────────┼───────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
┌─────────────────┐  ┌────────────────┐  ┌─────────────────┐
│ IndexStoreDB    │  │ DeclarationIdx │  │ ReferenceIndex  │
│ (Primary)       │  │ (Fallback)     │  │ (Usage data)    │
└─────────────────┘  └────────────────┘  └─────────────────┘
```

### 3.6 Search Algorithm

```swift
public actor SymbolFinder {
    private let indexReader: IndexStoreReader?
    private let syntaxIndex: DeclarationIndex
    private let referenceIndex: ReferenceIndex

    public func find(_ query: SymbolQuery) async -> [SymbolMatch] {
        // 1. Parse qualified name
        let components = parseQualifiedName(query.pattern)

        // 2. Try IndexStoreDB first (most accurate)
        if let indexReader {
            let results = try await findViaIndexStore(components, query: query)
            if !results.isEmpty {
                return results
            }
        }

        // 3. Fallback to syntax-based search
        return findViaSyntaxIndex(components, query: query)
    }

    private func parseQualifiedName(_ pattern: String) -> [String] {
        // Handle "NetworkMonitor.shared" → ["NetworkMonitor", "shared"]
        // Handle "shared" → ["shared"]
        // Handle "Module.Type.member" → ["Module", "Type", "member"]
        pattern.split(separator: ".").map(String.init)
    }

    private func findViaIndexStore(
        _ components: [String],
        query: SymbolQuery
    ) async throws -> [SymbolMatch] {
        guard let reader = indexReader else { return [] }

        if components.count == 1 {
            // Simple name search
            return reader.findOccurrences(ofSymbolNamed: components[0])
                .filter { matchesFilters($0, query: query) }
                .map { toSymbolMatch($0) }
        }

        // Qualified name: find container, then member
        let containerName = components.dropLast().joined(separator: ".")
        let memberName = components.last!

        // Find potential containers
        let containers = reader.findOccurrences(ofSymbolNamed: containerName)
            .filter { $0.roles.contains(.definition) }

        // Find members within those containers
        var matches: [SymbolMatch] = []
        for container in containers {
            let members = reader.findRelatedOccurrences(
                byUSR: container.symbol.usr,
                roles: [.definition, .reference]
            ).filter { $0.symbol.name == memberName }

            matches.append(contentsOf: members.map { toSymbolMatch($0) })
        }

        return matches.filter { matchesFilters($0, query: query) }
    }
}
```

### 3.7 Implementation Phases

#### Phase 1: Core Symbol Search
- [ ] Add `SymbolLookup` module
- [ ] Implement `SymbolQuery` and `SymbolMatch` models
- [ ] Implement `SymbolFinder` actor with IndexStoreDB backend
- [ ] Add basic CLI command: `swa symbol <name>`

#### Phase 2: Qualified Name Support
- [ ] Parse dot-notation (`Type.member`)
- [ ] Implement container-member resolution
- [ ] Support nested types (`Outer.Inner.member`)

#### Phase 3: Advanced Queries
- [ ] Kind filtering (`--kind`)
- [ ] Access level filtering (`--access`)
- [ ] File scope filtering (`--in-file`)
- [ ] Usage search (`--usages`)

#### Phase 4: Output & Integration
- [ ] JSON output format
- [ ] Xcode-compatible output
- [ ] Integration with existing analysis commands

---

## Part 4: References

### Language-Agnostic
- [Language Server Protocol Specification 3.17](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
- [Zoekt - Fast Trigram-Based Code Search](https://github.com/sourcegraph/zoekt)
- [Google Code Search - Trigram Index](https://swtch.com/~rsc/regexp/regexp4.html)
- [Tree-sitter](https://github.com/tree-sitter/tree-sitter)
- [Universal Ctags](https://github.com/universal-ctags/ctags)
- [Trigram-Based Persistent IDE Indices (2024)](https://arxiv.org/html/2403.03751v1)

### Swift-Specific
- [IndexStoreDB](https://github.com/swiftlang/indexstore-db)
- [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp)
- [Pecker - Unused Code Detection](https://github.com/woshiccm/Pecker)
- [Swift USR Forums Discussion](https://forums.swift.org/t/unified-symbol-resolution-giving-non-unique-resolution-of-variables/10812)
- [IndexStore for Swift Tutorial](https://cheekyghost.com/indexstore-for-swift)
- [Ctags with Swift](https://akrabat.com/ctags-with-swift/)

### Related Tools
- [swift-tree-sitter](https://github.com/tree-sitter/swift-tree-sitter)
- [swiftags (SourceKit-based ctags)](https://github.com/sharplet/swiftags)
- [NSHipster - LSP](https://nshipster.com/language-server-protocol/)
