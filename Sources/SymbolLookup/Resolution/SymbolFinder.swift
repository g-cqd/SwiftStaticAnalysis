//  SymbolFinder.swift
//  SwiftStaticAnalysis
//  MIT License

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
    private let accessLevelExtractor: AccessLevelExtractor
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
        self.accessLevelExtractor = AccessLevelExtractor()
        self.configuration = configuration
    }

    /// Creates a symbol finder without IndexStore (syntax-only mode).
    ///
    /// - Parameter configuration: Finder configuration.
    public init(configuration: Configuration = .default) {
        self.indexResolver = nil
        self.syntaxResolver = SyntaxResolver()
        self.accessLevelExtractor = AccessLevelExtractor()
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
        self.accessLevelExtractor = AccessLevelExtractor()
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

        // Enrich IndexStore results with access levels from source
        // IndexStore doesn't expose access levels, so we extract them from the source files
        if !matches.isEmpty {
            matches = accessLevelExtractor.enrichWithAccessLevels(matches)
        }

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
    /// Minimum number of queries required to enable parallel execution.
    private static let parallelThreshold = 3

    /// Finds multiple symbols in a single operation.
    ///
    /// - Parameters:
    ///   - queries: Array of queries to execute.
    ///   - parallelMode: Parallel execution mode. Defaults to `.maximum`.
    /// - Returns: Dictionary mapping query descriptions to results.
    ///
    /// - Note: Parallelization is only used when there are 3+ queries and
    ///   `parallelMode` is not `.none`. For small numbers of queries,
    ///   sequential execution is used to avoid TaskGroup overhead.
    ///
    /// - Complexity: O(n * m) where n is queries and m is symbols per query.
    ///   With parallelization, effective time is O(m * n/cores).
    public func findMultiple(
        _ queries: [SymbolQuery],
        parallelMode: ParallelMode = .maximum
    ) async throws -> [String: [SymbolMatch]] {
        guard !queries.isEmpty else { return [:] }

        // Use sequential execution for small batches or when parallelization is disabled
        if queries.count < Self.parallelThreshold || parallelMode == .none {
            return try await findMultipleSequential(queries)
        }

        // Parallel execution with concurrency limit
        let concurrency = parallelMode.toConcurrencyConfiguration()
        let indexedQueries = queries.enumerated().map { ($0.offset, $0.element) }

        let indexedResults = try await ParallelProcessor.map(
            indexedQueries,
            maxConcurrency: concurrency.maxConcurrentTasks
        ) { [self] (index, query) in
            let matches = try await self.find(query)
            return (index, query.description, matches)
        }

        // Build results dictionary preserving original query order
        var results: [String: [SymbolMatch]] = [:]
        results.reserveCapacity(queries.count)
        for (_, description, matches) in indexedResults.sorted(by: { $0.0 < $1.0 }) {
            results[description] = matches
        }

        return results
    }

    /// Sequential implementation of findMultiple for small batches.
    private func findMultipleSequential(_ queries: [SymbolQuery]) async throws -> [String: [SymbolMatch]] {
        var results: [String: [SymbolMatch]] = [:]
        results.reserveCapacity(queries.count)

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
        findReferencedUSRsSync(usrs)
    }

    /// Synchronous implementation that acquires lock once for all USRs.
    private func findReferencedUSRsSync(_ usrs: [String]) -> Set<String> {
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

    /// Minimum number of USRs required to enable chunked parallel processing.
    private static let usrChunkThreshold = 50

    /// Chunk size for parallel USR processing.
    /// Chosen to balance lock contention vs parallelism overhead.
    private static let usrChunkSize = 100

    /// Checks if any of the given symbols have references using parallel chunked processing.
    ///
    /// - Parameters:
    ///   - usrs: Array of USRs to check.
    ///   - parallelMode: Parallel execution mode.
    /// - Returns: Set of USRs that have references.
    ///
    /// - Note: For large USR sets (>50), processes USRs in chunks of 100 to balance
    ///   lock contention against parallelism overhead. Each chunk acquires the lock
    ///   once for all USRs in that chunk.
    ///
    /// - Complexity: O(n) where n is USRs. With parallelization, effective time
    ///   is O(n / (cores * chunkSize)) * chunkProcessingTime.
    public func findReferencedUSRs(
        _ usrs: [String],
        parallelMode: ParallelMode
    ) async -> Set<String> {
        guard indexResolver != nil else {
            return []
        }

        guard !usrs.isEmpty else { return [] }

        // Use sequential execution for small batches or when parallelization is disabled
        if usrs.count < Self.usrChunkThreshold || parallelMode == .none {
            return findReferencedUSRsSync(usrs)
        }

        // Split into chunks for parallel processing
        let chunks = stride(from: 0, to: usrs.count, by: Self.usrChunkSize).map { startIndex in
            let endIndex = min(startIndex + Self.usrChunkSize, usrs.count)
            return Array(usrs[startIndex..<endIndex])
        }

        let concurrency = parallelMode.toConcurrencyConfiguration()

        // Process chunks in parallel, each chunk uses synchronous helper
        let chunkResults = await ParallelProcessor.compactMap(
            chunks,
            maxConcurrency: concurrency.maxConcurrentTasks
        ) { [self] chunk -> Set<String>? in
            // Use synchronous helper to avoid async context issues with NSLock
            let referenced = self.checkReferencesForChunkSync(chunk)
            return referenced.isEmpty ? nil : referenced
        }

        // Combine results from all chunks
        var allReferenced = Set<String>()
        for chunkSet in chunkResults {
            allReferenced.formUnion(chunkSet)
        }

        return allReferenced
    }

    /// Synchronous helper for checking references in a chunk.
    ///
    /// - Parameter chunk: Array of USRs to check.
    /// - Returns: Set of USRs that have references.
    ///
    /// - Note: SAFETY: Lock is acquired for the entire chunk.
    private func checkReferencesForChunkSync(_ chunk: [String]) -> Set<String> {
        guard let indexResolver else { return [] }

        lock.lock()
        defer { lock.unlock() }

        var referenced = Set<String>()
        for usr in chunk {
            if indexResolver.hasReferencesSync(usr: usr) {
                referenced.insert(usr)
            }
        }
        return referenced
    }
}
