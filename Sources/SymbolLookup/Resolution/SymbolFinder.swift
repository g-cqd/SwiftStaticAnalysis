//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftStaticAnalysis open source project
//
// Copyright (c) 2024 the SwiftStaticAnalysis project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftStaticAnalysisCore
import UnusedCodeDetector

/// Main coordinator for symbol lookup operations.
///
/// Combines IndexStore-based resolution (when available) with
/// syntax-based fallback for comprehensive symbol lookup.
///
/// ## Thread Safety Design
///
/// This class uses `@unchecked Sendable` with `NSLock` for thread safety instead
/// of Swift's `actor` model. This design choice was made because:
///
/// 1. **Non-Sendable Dependency**: `IndexStoreDB` from the `IndexStoreDB` package
///    is not `Sendable`. Passing it to an actor method causes "sending risks data
///    race" errors in Swift 6 strict concurrency mode.
///
/// 2. **Closure-Based APIs**: `IndexStoreDB` uses callback closures that capture
///    `self`. In an actor context, these closures would need to be `@Sendable`,
///    but they access actor-isolated state.
///
/// 3. **Performance**: The `NSLock` pattern allows synchronous access for
///    read-heavy operations without the overhead of `await` at every call site.
///
/// ## SAFETY: Lock Usage
///
/// The `lock` protects all access to `indexResolver` which wraps the non-Sendable
/// `IndexStoreDB`. The lock is acquired before any IndexStore operation and
/// released immediately after. All public async methods properly acquire the
/// lock for IndexStore operations.
///
/// - **Invariant**: `indexResolver` is only accessed while `lock` is held.
/// - **No Deadlock**: Lock is never held across await points.
///
/// - SeeAlso: `IndexBasedDependencyGraph` which uses the same pattern.
/// - SeeAlso: `ReachabilityGraph` which uses `actor` (no non-Sendable deps).
///
/// ## Resolution Strategy
///
/// 1. If IndexStore is available, use USR-based O(log n) lookup
/// 2. Fall back to syntax-based O(n) resolution when needed
/// 3. Combine results and deduplicate by location
public final class SymbolFinder: @unchecked Sendable {
    // SAFETY: lock protects all access to indexResolver. The lock is acquired
    // before any IndexStore operation and released immediately after, ensuring
    // no data races on the underlying non-Sendable IndexStoreDB.
    private let lock = NSLock()
    private let indexResolver: IndexStoreResolver?
    private let syntaxResolver: SyntaxResolver
    private let configuration: Configuration

    /// Configuration for the symbol finder.
    public struct Configuration: Sendable {
        /// Whether to fall back to syntax resolution when index is unavailable.
        public var useSyntaxFallback: Bool

        /// Files to include in syntax-based resolution.
        public var sourceFiles: [String]

        /// Whether to include system symbols in results.
        public var includeSystemSymbols: Bool

        /// Default configuration.
        public static let `default` = Configuration(
            useSyntaxFallback: true,
            sourceFiles: [],
            includeSystemSymbols: false
        )

        /// Creates a new configuration.
        public init(
            useSyntaxFallback: Bool = true,
            sourceFiles: [String] = [],
            includeSystemSymbols: Bool = false
        ) {
            self.useSyntaxFallback = useSyntaxFallback
            self.sourceFiles = sourceFiles
            self.includeSystemSymbols = includeSystemSymbols
        }
    }

    /// Creates a symbol finder with an IndexStore.
    ///
    /// - Parameters:
    ///   - indexStorePath: Path to the index store directory.
    ///   - configuration: Finder configuration.
    /// - Throws: `IndexStoreError` if the index cannot be opened.
    public init(
        indexStorePath: String,
        configuration: Configuration = .default
    ) throws {
        let reader = try IndexStoreReader(indexStorePath: indexStorePath)
        self.indexResolver = IndexStoreResolver(reader: reader)
        self.syntaxResolver = SyntaxResolver()
        self.configuration = configuration
    }

    /// Creates a symbol finder without IndexStore (syntax-only mode).
    ///
    /// - Parameter configuration: Finder configuration.
    public init(configuration: Configuration = .default) {
        self.indexResolver = nil
        self.syntaxResolver = SyntaxResolver()
        self.configuration = configuration
    }

    /// Creates a symbol finder that auto-discovers IndexStore.
    ///
    /// - Parameters:
    ///   - projectPath: Path to the project root.
    ///   - configuration: Finder configuration.
    public init(
        projectPath: String,
        configuration: Configuration = .default
    ) {
        if let indexPath = IndexStorePathFinder.findIndexStorePath(in: projectPath),
            let reader = try? IndexStoreReader(indexStorePath: indexPath)
        {
            self.indexResolver = IndexStoreResolver(reader: reader)
        } else {
            self.indexResolver = nil
        }
        self.syntaxResolver = SyntaxResolver()
        self.configuration = configuration
    }

    /// Whether IndexStore is available.
    public var hasIndexStore: Bool {
        indexResolver != nil
    }
}

// MARK: - Symbol Lookup

extension SymbolFinder {
    /// Finds symbols matching a query.
    ///
    /// - Parameter query: The symbol query.
    /// - Returns: Array of matching symbols.
    public func find(_ query: SymbolQuery) async throws -> [SymbolMatch] {
        // Try IndexStore first (synchronous)
        var matches = resolveWithIndex(query.pattern)

        // Fall back to syntax if needed (async)
        if matches.isEmpty && configuration.useSyntaxFallback && !configuration.sourceFiles.isEmpty {
            // USR queries don't work with syntax resolver
            if !query.pattern.isUSR {
                let syntaxMatches = try await syntaxResolver.resolve(
                    query.pattern,
                    in: configuration.sourceFiles
                )
                matches.append(contentsOf: syntaxMatches)
            }
        }

        // Apply filters
        matches = applyFilters(matches, query: query)

        // Filter by mode
        matches = filterByMode(matches, mode: query.mode)

        // Apply limit
        if query.limit > 0 {
            matches = Array(matches.prefix(query.limit))
        }

        return matches.sorted()
    }

    /// Finds a symbol by name.
    ///
    /// - Parameter name: The symbol name.
    /// - Returns: Array of matching symbols.
    public func findByName(_ name: String) async throws -> [SymbolMatch] {
        try await find(SymbolQuery.name(name))
    }

    /// Finds a symbol by qualified name.
    ///
    /// - Parameter qualifiedName: The qualified name (e.g., "Type.member").
    /// - Returns: Array of matching symbols.
    public func findByQualifiedName(_ qualifiedName: String) async throws -> [SymbolMatch] {
        try await find(SymbolQuery.qualified(qualifiedName))
    }

    /// Finds a symbol by USR.
    ///
    /// - Parameter usr: The Unified Symbol Resolution string.
    /// - Returns: Array of matching symbols.
    public func findByUSR(_ usr: String) async throws -> [SymbolMatch] {
        try await find(SymbolQuery.usr(usr))
    }

    /// Finds all usages of a symbol.
    ///
    /// - Parameter match: The symbol to find usages for.
    /// - Returns: Array of occurrence locations.
    public func findUsages(of match: SymbolMatch) async throws -> [SymbolOccurrence] {
        // Prefer IndexStore for usages (synchronous)
        if match.usr != nil {
            let usages = findUsagesWithIndex(match)
            if !usages.isEmpty {
                return usages
            }
        }

        // Fall back to syntax-based reference finding (async)
        if configuration.useSyntaxFallback && !configuration.sourceFiles.isEmpty {
            return try await syntaxResolver.findReferences(
                to: match,
                in: configuration.sourceFiles
            )
        }

        return []
    }
}

// MARK: - Synchronous IndexStore Access

extension SymbolFinder {
    /// Resolves a pattern using IndexStore (thread-safe, synchronous).
    ///
    /// - Parameter pattern: The query pattern to resolve.
    /// - Returns: Array of matching symbols.
    ///
    /// - Note: SAFETY: Lock is acquired for the duration of the IndexStore call.
    private func resolveWithIndex(_ pattern: SymbolQuery.Pattern) -> [SymbolMatch] {
        guard let indexResolver else { return [] }

        // SAFETY: Lock protects access to indexResolver which wraps non-Sendable IndexStoreDB.
        // Lock is released immediately after the synchronous operation completes.
        lock.lock()
        defer { lock.unlock() }

        return indexResolver.resolveSync(pattern)
    }

    /// Finds usages using IndexStore (thread-safe, synchronous).
    ///
    /// - Parameter match: The symbol to find usages for.
    /// - Returns: Array of occurrence locations.
    ///
    /// - Note: SAFETY: Lock is acquired for the duration of the IndexStore call.
    private func findUsagesWithIndex(_ match: SymbolMatch) -> [SymbolOccurrence] {
        guard let indexResolver else { return [] }

        // SAFETY: Lock protects access to indexResolver which wraps non-Sendable IndexStoreDB.
        // Lock is released immediately after the synchronous operation completes.
        lock.lock()
        defer { lock.unlock() }

        return indexResolver.findUsagesSync(of: match)
    }
}

// MARK: - Filtering

extension SymbolFinder {
    private func applyFilters(_ matches: [SymbolMatch], query: SymbolQuery) -> [SymbolMatch] {
        var filtered = matches

        // Filter by kind
        if let kinds = query.kindFilter {
            filtered = filtered.filter { kinds.contains($0.kind) }
        }

        // Filter by access level
        if let levels = query.accessFilter {
            filtered = filtered.filter { levels.contains($0.accessLevel) }
        }

        // Filter by scope
        if let scope = query.scopeFilter {
            filtered = filtered.filter { $0.containingType == scope }
        }

        // Deduplicate by location
        var seen = Set<String>()
        filtered = filtered.filter { match in
            let key = match.locationString
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }

        return filtered
    }

    private func filterByMode(_ matches: [SymbolMatch], mode: SymbolQuery.Mode) -> [SymbolMatch] {
        // For now, all matches from resolution are definitions
        // Mode filtering is more relevant when combining with usages
        switch mode {
        case .definition, .all:
            return matches
        case .usages:
            // In usages mode, we return empty here
            // Caller should use findUsages instead
            return matches
        }
    }
}

// MARK: - Batch Operations

extension SymbolFinder {
    /// Finds multiple symbols in a single operation.
    ///
    /// - Parameter queries: Array of queries to execute.
    /// - Returns: Dictionary mapping query descriptions to results.
    public func findMultiple(_ queries: [SymbolQuery]) async throws -> [String: [SymbolMatch]] {
        var results: [String: [SymbolMatch]] = [:]

        for query in queries {
            let matches = try await find(query)
            results[query.description] = matches
        }

        return results
    }

    /// Checks if any of the given symbols have references.
    ///
    /// - Parameter usrs: Array of USRs to check.
    /// - Returns: Set of USRs that have references.
    ///
    /// - Note: SAFETY: Lock is acquired for the duration of all IndexStore calls.
    public func findReferencedUSRs(_ usrs: [String]) -> Set<String> {
        guard let indexResolver else {
            return []
        }

        // SAFETY: Lock protects access to indexResolver which wraps non-Sendable IndexStoreDB.
        // Lock is held for all reference checks to avoid repeated lock/unlock overhead.
        lock.lock()
        defer { lock.unlock() }

        var referenced = Set<String>()

        for usr in usrs {
            if indexResolver.hasReferencesSync(usr: usr) {
                referenced.insert(usr)
            }
        }

        return referenced
    }
}
