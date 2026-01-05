//  SymbolResolver.swift
//  SwiftStaticAnalysis
//  MIT License

/// Protocol for symbol resolution.
///
/// Provides a common interface for resolving symbol queries using different
/// backends (IndexStore, Syntax parsing, etc.). This enables dependency
/// injection and testing with mock resolvers.
///
/// ## Conforming Types
///
/// - ``IndexStoreResolver``: Uses IndexStoreDB for O(log n) USR-based lookups
/// - ``SyntaxResolver``: Uses SwiftSyntax for O(n) source-based resolution
///
/// ## Thread Safety
///
/// Implementations must be safe to call from any thread. The protocol is
/// `Sendable` to enforce this requirement.
public protocol SymbolResolver: Sendable {
    /// Resolves a query pattern to matching symbols.
    ///
    /// - Parameter pattern: The query pattern to resolve.
    /// - Returns: Array of matching symbols.
    /// - Throws: Implementation-specific errors during resolution.
    ///
    /// - Complexity: Varies by implementation. `IndexStoreResolver` provides
    ///   O(log n) for USR queries; `SyntaxResolver` provides O(n).
    func resolve(_ pattern: SymbolQuery.Pattern) async throws -> [SymbolMatch]
}

/// Protocol for resolvers that can find symbol usages.
///
/// Not all resolvers support usage finding. `IndexStoreResolver` can find
/// usages via USR lookup, while `SyntaxResolver` uses text-based searching.
public protocol UsageResolver: SymbolResolver {
    /// Finds all occurrences (usages) of a symbol.
    ///
    /// - Parameter match: The symbol to find usages for.
    /// - Returns: Array of occurrence locations.
    /// - Throws: Implementation-specific errors during resolution.
    func findUsages(of match: SymbolMatch) async throws -> [SymbolOccurrence]
}

/// Protocol for resolvers that can check for references.
///
/// Provides an optimized path for checking if a symbol has any references
/// without retrieving all of them.
public protocol ReferenceChecker: SymbolResolver {
    /// Checks if a symbol has any references.
    ///
    /// - Parameter usr: The USR of the symbol.
    /// - Returns: `true` if the symbol is referenced.
    ///
    /// - Complexity: O(1) to O(log n) depending on implementation.
    func hasReferences(usr: String) async -> Bool
}
