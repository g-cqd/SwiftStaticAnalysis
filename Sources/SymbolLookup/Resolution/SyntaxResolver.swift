//  SyntaxResolver.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore

/// Resolves symbols using SwiftSyntax-based parsing.
///
/// This resolver provides a fallback when IndexStore is not available.
/// It parses source files directly and searches the declaration index.
///
/// ## Thread Safety
///
/// This type is `Sendable` and thread-safe. The underlying `StaticAnalyzer`
/// handles concurrent access correctly.
///
/// - Note: This resolver has O(n) complexity and does not support
///   cross-module resolution. Prefer `IndexStoreResolver` when available.
///
/// - SeeAlso: ``SymbolResolver`` for the protocol this type conforms to.
/// - SeeAlso: ``IndexStoreResolver`` for IndexStore-based resolution.
public struct SyntaxResolver: Sendable {
    private let analyzer: StaticAnalyzer

    /// Source files to search when resolving without explicit file list.
    private let defaultFiles: [String]

    /// Creates a new syntax resolver.
    ///
    /// - Parameters:
    ///   - analyzer: The static analyzer for parsing files.
    ///   - defaultFiles: Default files to search when no files are specified.
    public init(analyzer: StaticAnalyzer = StaticAnalyzer(), defaultFiles: [String] = []) {
        self.analyzer = analyzer
        self.defaultFiles = defaultFiles
    }

    /// Resolves a query pattern in the given files.
    ///
    /// - Parameters:
    ///   - pattern: The query pattern to resolve.
    ///   - files: Files to search in.
    /// - Returns: Array of matching symbols.
    ///
    /// - Complexity: O(n) where n is the total number of declarations.
    public func resolve(
        _ pattern: SymbolQuery.Pattern,
        in files: [String]
    ) async throws -> [SymbolMatch] {
        // Parse all files
        let result = try await analyzer.analyze(files)

        switch pattern {
        case .simpleName(let name):
            return resolveByName(name, in: result)
        case .qualifiedName(let components):
            return resolveQualifiedName(components, in: result)
        case .selector(let name, let labels):
            return resolveBySelector(name: name, labels: labels, in: result)
        case .qualifiedSelector(let types, let name, let labels):
            return resolveQualifiedSelector(types: types, name: name, labels: labels, in: result)
        case .usr(let usr):
            // USR resolution requires IndexStoreDB; the syntax-only
            // resolver cannot decode mangled symbol references. Throw
            // a typed error so the caller can't silently get empty
            // results — the previous `return []` was the canonical
            // "silent no-op" footgun the post-α.15 audit flagged.
            throw SyntaxResolverError.usrResolutionRequiresIndexStore(usr: usr)
        case .regex(let regex):
            return try resolveByRegex(regex, in: result)
        }
    }
}

// MARK: - SymbolResolver Conformance

extension SyntaxResolver: SymbolResolver {
    /// Resolves a query pattern using the default files.
    ///
    /// - Parameter pattern: The query pattern to resolve.
    /// - Returns: Array of matching symbols.
    /// - Throws: If parsing fails or no default files are configured.
    ///
    /// - Complexity: O(n) where n is the total number of declarations.
    public func resolve(_ pattern: SymbolQuery.Pattern) async throws -> [SymbolMatch] {
        try await resolve(pattern, in: defaultFiles)
    }
}

// MARK: - Reference Finding

extension SyntaxResolver {
    /// Finds references to a symbol in the given files.
    ///
    /// - Parameters:
    ///   - match: The symbol to find references for.
    ///   - files: Files to search in.
    /// - Returns: Array of reference locations.
    public func findReferences(
        to match: SymbolMatch,
        in files: [String]
    ) async throws -> [SymbolOccurrence] {
        let result = try await analyzer.analyze(files)

        let references = result.references.find(identifier: match.name)

        return references.map { ref in
            SymbolOccurrence(
                file: ref.location.file,
                line: ref.location.line,
                column: ref.location.column,
                kind: convertContextToKind(ref.context)
            )
        }
    }
}

// MARK: - Private Resolution Methods

extension SyntaxResolver {
    private func resolveByName(_ name: String, in result: AnalysisResult) -> [SymbolMatch] {
        let declarations = result.declarations.find(name: name)

        return declarations.map { decl in
            convertToSymbolMatch(decl, scopeTree: result.scopes)
        }
    }

    private func resolveQualifiedName(
        _ components: [String],
        in result: AnalysisResult
    ) -> [SymbolMatch] {
        guard components.count >= 2,
            let memberName = components.last
        else {
            return components.first.map { resolveByName($0, in: result) } ?? []
        }

        // Walk the full container chain (e.g. `Outer.Inner.method` →
        // expected chain `["Outer", "Inner"]`). The previous
        // implementation only checked the immediate container
        // (`components.dropLast().last`), so deeply nested types
        // silently dropped to recall-loss territory.
        let expectedChain = Array(components.dropLast())
        let immediateContainerName = expectedChain.last ?? ""

        // Find all declarations with the member name
        let memberDecls = result.declarations.find(name: memberName)

        // Filter to those whose enclosing-scope chain matches the
        // full expected container chain.
        return memberDecls.compactMap { decl -> SymbolMatch? in
            guard containingTypeChain(for: decl, in: result) == expectedChain else {
                return nil
            }

            let match = convertToSymbolMatch(decl, scopeTree: result.scopes)
            return match.withContainingType(immediateContainerName)
        }
    }

    /// Walk outward from `decl`'s scope, collecting the names of every
    /// enclosing type / extension declaration in outer-to-inner order.
    /// Used to match a qualified-name request against the actual scope
    /// nesting. Mirrors the single-step `findContainingType` walk but
    /// continues past the first hit so deeply nested types
    /// (`Outer.Inner.Leaf.method`) resolve correctly.
    private func containingTypeChain(
        for decl: Declaration,
        in result: AnalysisResult,
    ) -> [String] {
        var chain: [String] = []
        var currentScope: ScopeID? = decl.scope
        while let scopeID = currentScope, let scope = result.scopes.scope(for: scopeID) {
            switch scope.kind {
            case .actor, .class, .struct, .enum, .protocol, .extension:
                if let typeName = scope.name {
                    chain.append(typeName)
                }
            default:
                break
            }
            currentScope = scope.parent
        }
        return chain.reversed()
    }

    /// Default regex query matches by **whole-identifier** (full-name
    /// match), not substring. The previous `.contains(regex)` shape
    /// turned a query like `"load"` into a hit on `loadUsers`,
    /// `uploadData`, `download`, and `reloadAll` — over-eager and
    /// rarely what users want from a name-search interface. Callers
    /// who want substring matching can supply an explicit
    /// substring-shaped regex (`.*load.*`).
    private func resolveByRegex(_ pattern: String, in result: AnalysisResult) throws -> [SymbolMatch] {
        let regex = try Regex(pattern)

        let allDeclarations = result.declarations.declarations

        return
            allDeclarations
            .filter { decl in
                decl.name.wholeMatch(of: regex) != nil
            }
            .map { convertToSymbolMatch($0, scopeTree: result.scopes) }
    }

    private func resolveBySelector(
        name: String,
        labels: [String?],
        in result: AnalysisResult
    ) -> [SymbolMatch] {
        // Find all declarations with the base name
        let declarations = result.declarations.find(name: name)

        // Filter to those matching the selector labels
        return
            declarations
            .map { convertToSymbolMatch($0, scopeTree: result.scopes) }
            .filter { matchesSelector($0, labels: labels) }
    }

    private func resolveQualifiedSelector(
        types: [String],
        name: String,
        labels: [String?],
        in result: AnalysisResult
    ) -> [SymbolMatch] {
        let containerName = types.last ?? ""

        // Find all declarations with the member name
        let memberDecls = result.declarations.find(name: name)

        // Filter to those inside the container and matching selector
        return memberDecls.compactMap { decl -> SymbolMatch? in
            // Check if this declaration is inside the container
            let containerDecl = findContainingType(for: decl, in: result)

            guard containerDecl?.name == containerName else {
                return nil
            }

            let match = convertToSymbolMatch(decl, scopeTree: result.scopes)

            // Check selector matches
            guard matchesSelector(match, labels: labels) else {
                return nil
            }

            return match.withContainingType(containerName)
        }
    }

    /// Checks if a symbol match's signature matches the given selector labels.
    private func matchesSelector(_ match: SymbolMatch, labels: [String?]) -> Bool {
        guard let signature = match.signature else {
            // No signature = no parameters, matches empty labels
            return labels.isEmpty
        }

        // Must have same number of parameters
        guard signature.parameters.count == labels.count else {
            return false
        }

        // Check each label
        for (param, queryLabel) in zip(signature.parameters, labels) {
            let paramLabel = param.label  // nil for unlabeled

            // Both must match: nil == nil (unlabeled), or strings match
            if paramLabel != queryLabel {
                return false
            }
        }

        return true
    }

    private func findContainingType(
        for declaration: Declaration,
        in result: AnalysisResult
    ) -> Declaration? {
        // Walk up the scope tree to find the containing type
        var currentScope = declaration.scope

        while let scope = result.scopes.scope(for: currentScope) {
            // Check if this scope is a type
            switch scope.kind {
            case .actor, .class, .struct, .enum, .protocol, .extension:
                // Find the declaration for this scope
                if let typeName = scope.name {
                    return result.declarations.find(name: typeName).first
                }
            default:
                break
            }

            // Move to parent
            if let parent = scope.parent {
                currentScope = parent
            } else {
                break
            }
        }

        return nil
    }
}

// MARK: - Conversion Helpers

extension SyntaxResolver {
    private func convertToSymbolMatch(
        _ declaration: Declaration,
        scopeTree: ScopeTree
    ) -> SymbolMatch {
        // Find containing type from scope
        var containingType: String?
        var currentScope = declaration.scope

        while let scope = scopeTree.scope(for: currentScope) {
            switch scope.kind {
            case .actor, .class, .struct, .enum, .protocol, .extension:
                containingType = scope.name
                break
            default:
                if let parent = scope.parent {
                    currentScope = parent
                } else {
                    break
                }
                continue
            }
            break
        }

        return SymbolMatch.from(
            declaration: declaration,
            containingType: containingType,
            source: .syntaxTree
        )
    }

    private func convertContextToKind(_ context: ReferenceContext) -> SymbolOccurrence.Kind {
        switch context {
        case .call:
            return .call
        case .read:
            return .read
        case .write:
            return .write
        default:
            return .reference
        }
    }
}

// MARK: - SyntaxResolverError

/// Errors thrown by `SyntaxResolver` when a query is structurally
/// unresolvable through syntax-only analysis.
public enum SyntaxResolverError: Error, Sendable, CustomStringConvertible {
    /// A `.usr(...)` query was issued but the resolver has no
    /// IndexStoreDB backing. Switch to `--mode indexStore` or supply
    /// `--index-store-path`.
    case usrResolutionRequiresIndexStore(usr: String)

    public var description: String {
        switch self {
        case .usrResolutionRequiresIndexStore(let usr):
            return
                "SyntaxResolver cannot resolve USR '\(usr)'. USR resolution requires IndexStoreDB; use `--mode indexStore` or supply `--index-store-path`."
        }
    }
}
