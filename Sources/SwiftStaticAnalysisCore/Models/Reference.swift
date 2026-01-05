//  Reference.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - ReferenceContext

/// The context in which an identifier is referenced.
public enum ReferenceContext: String, Sendable, Codable {
    /// Function or method call: `foo()`
    case call

    /// Reading a variable: `let x = foo`
    case read

    /// Writing to a variable: `foo = x`
    case write

    /// Type annotation: `let x: Foo`
    case typeAnnotation

    /// Inheritance or conformance: `class Bar: Foo`
    case inheritance

    /// Generic constraint: `where T: Foo`
    case genericConstraint

    /// Import statement: `import Foo`
    case `import`

    /// Attribute: `@Foo`
    case attribute

    /// Member access base: `foo.bar`
    case memberAccessBase

    /// Member access member: `foo.bar`
    case memberAccessMember

    /// Key path: `\Foo.bar`
    case keyPath

    /// Pattern matching: `case .foo`
    case pattern

    /// Unknown context
    case unknown
}

// MARK: - Reference

/// Represents a reference to an identifier in source code.
public struct Reference: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(
        identifier: String,
        location: SourceLocation,
        scope: ScopeID,
        context: ReferenceContext,
        isQualified: Bool = false,
        qualifier: String? = nil,
    ) {
        self.identifier = identifier
        self.location = location
        self.scope = scope
        self.context = context
        self.isQualified = isQualified
        self.qualifier = qualifier
    }

    // MARK: Public

    /// The referenced identifier.
    public let identifier: String

    /// Location of the reference.
    public let location: SourceLocation

    /// Scope containing the reference.
    public let scope: ScopeID

    /// Context of the reference.
    public let context: ReferenceContext

    /// Whether this is a qualified reference (e.g., `Module.Type`).
    public let isQualified: Bool

    /// The qualifier if qualified (e.g., `Module` in `Module.Type`).
    public let qualifier: String?
}

// MARK: - ReferenceIndex

/// Index of references for fast lookup.
public struct ReferenceIndex: Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// All references.
    public private(set) var references: [Reference] = []

    /// References indexed by identifier.
    public private(set) var byIdentifier: [String: [Reference]] = [:]

    /// References indexed by context.
    public private(set) var byContext: [ReferenceContext: [Reference]] = [:]

    /// References indexed by file.
    public private(set) var byFile: [String: [Reference]] = [:]

    /// References indexed by scope.
    public private(set) var byScope: [ScopeID: [Reference]] = [:]

    /// Get all unique referenced identifiers.
    public var uniqueIdentifiers: Set<String> {
        Set(byIdentifier.keys)
    }

    /// Add a reference to the index.
    public mutating func add(_ reference: Reference) {
        references.append(reference)
        byIdentifier[reference.identifier, default: []].append(reference)
        byContext[reference.context, default: []].append(reference)
        byFile[reference.location.file, default: []].append(reference)
        byScope[reference.scope, default: []].append(reference)
    }

    /// Find references to an identifier.
    public func find(identifier: String) -> [Reference] {
        byIdentifier[identifier] ?? []
    }

    /// Find references of a specific context type.
    public func find(context: ReferenceContext) -> [Reference] {
        byContext[context] ?? []
    }

    /// Find references in a specific file.
    public func find(inFile file: String) -> [Reference] {
        byFile[file] ?? []
    }

    /// Find references in a specific scope.
    public func find(inScope scope: ScopeID) -> [Reference] {
        byScope[scope] ?? []
    }
}
