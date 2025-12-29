//
//  Scope.swift
//  SwiftStaticAnalysis
//

import Foundation

// MARK: - ScopeID

/// Unique identifier for a lexical scope.
public struct ScopeID: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(_ id: String) {
        self.id = id
    }

    // MARK: Public

    /// The global/file scope.
    public static let global = ScopeID("global")

    /// The underlying identifier.
    public let id: String
}

// MARK: - ScopeKind

/// The kind of lexical scope.
/// Intentionally exhaustive to cover all Swift scope types. // swa:ignore-unused-cases
public enum ScopeKind: String, Sendable, Codable {
    case global
    case file
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case function
    case closure
    case `if`
    case `guard`
    case `for`
    case `while`
    case `switch`
    case `do`
}

// MARK: - Scope

/// Represents a lexical scope in the source code.
public struct Scope: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(
        id: ScopeID,
        kind: ScopeKind,
        name: String? = nil,
        parent: ScopeID? = nil,
        location: SourceLocation,
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.parent = parent
        self.location = location
    }

    // MARK: Public

    /// Unique identifier for this scope.
    public let id: ScopeID

    /// The kind of scope.
    public let kind: ScopeKind

    /// Name of the scope (e.g., function name, type name).
    public let name: String?

    /// Parent scope ID (nil for global scope).
    public let parent: ScopeID?

    /// Location where the scope begins.
    public let location: SourceLocation
}

// MARK: - ScopeTree

/// A tree structure for tracking scope hierarchy.
public struct ScopeTree: Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// All scopes indexed by ID.
    public private(set) var scopes: [ScopeID: Scope] = [:]

    /// Children of each scope.
    public private(set) var children: [ScopeID: [ScopeID]] = [:]

    /// Add a scope to the tree.
    public mutating func add(_ scope: Scope) {
        scopes[scope.id] = scope

        if let parent = scope.parent {
            children[parent, default: []].append(scope.id)
        }
    }

    /// Get the scope for an ID.
    public func scope(for id: ScopeID) -> Scope? {
        scopes[id]
    }

    /// Get the parent chain for a scope.
    public func ancestors(of id: ScopeID) -> [Scope] {
        var result: [Scope] = []
        var currentID = id

        while let scope = scopes[currentID], let parentID = scope.parent {
            if let parent = scopes[parentID] {
                result.append(parent)
                currentID = parentID
            } else {
                break
            }
        }

        return result
    }

    /// Check if a scope is an ancestor of another.
    public func isAncestor(_ ancestorID: ScopeID, of descendantID: ScopeID) -> Bool {
        var currentID = descendantID

        while let scope = scopes[currentID] {
            if scope.id == ancestorID {
                return true
            }
            guard let parentID = scope.parent else {
                return false
            }
            currentID = parentID
        }

        return false
    }

    /// Get the nearest enclosing scope of a specific kind.
    public func nearestScope(of kind: ScopeKind, from id: ScopeID) -> Scope? {
        var currentID = id

        while let scope = scopes[currentID] {
            if scope.kind == kind {
                return scope
            }
            guard let parentID = scope.parent else {
                return nil
            }
            currentID = parentID
        }

        return nil
    }
}
