//
//  ScopeTracker.swift
//  SwiftStaticAnalysis
//

import Foundation
import SwiftSyntax

// MARK: - Scope Tracker

/// Tracks lexical scopes during AST traversal.
///
/// This utility builds a scope tree as you traverse the AST,
/// maintaining a stack of current scopes and generating unique scope IDs.
public struct ScopeTracker: Sendable {
    /// The file being tracked.
    public let file: String

    /// Current scope stack.
    private var scopeStack: [ScopeID]

    /// Counter for generating unique scope IDs.
    private var scopeCounter: Int

    /// The scope tree being built.
    public private(set) var tree: ScopeTree

    public init(file: String) {
        self.file = file
        self.scopeStack = [.global]
        self.scopeCounter = 0
        self.tree = ScopeTree()

        // Add the global scope
        let globalScope = Scope(
            id: .global,
            kind: .global,
            name: nil,
            parent: nil,
            location: SourceLocation(file: file, line: 1, column: 1)
        )
        tree.add(globalScope)
    }

    /// The current scope.
    public var currentScope: ScopeID {
        scopeStack.last ?? .global
    }

    /// Enter a new scope.
    ///
    /// - Parameters:
    ///   - kind: The kind of scope.
    ///   - name: Optional name for the scope.
    ///   - location: Source location of the scope.
    /// - Returns: The ID of the new scope.
    @discardableResult
    public mutating func enterScope(
        kind: ScopeKind,
        name: String? = nil,
        location: SourceLocation
    ) -> ScopeID {
        scopeCounter += 1
        let scopeID = ScopeID("\(file):\(scopeCounter)")

        let scope = Scope(
            id: scopeID,
            kind: kind,
            name: name,
            parent: currentScope,
            location: location
        )

        tree.add(scope)
        scopeStack.append(scopeID)

        return scopeID
    }

    /// Exit the current scope.
    public mutating func exitScope() {
        guard scopeStack.count > 1 else { return }
        scopeStack.removeLast()
    }

    /// Get the full scope path (for debugging).
    public var scopePath: String {
        scopeStack.map { $0.id }.joined(separator: " > ")
    }
}

// MARK: - Scope Tracking Visitor

/// A syntax visitor that tracks scopes automatically.
///
/// Subclass this to get automatic scope tracking as you traverse the AST.
open class ScopeTrackingVisitor: SyntaxVisitor {
    /// The scope tracker.
    public var tracker: ScopeTracker

    /// The source location converter.
    public let converter: SourceLocationConverter

    /// The file being visited.
    public let file: String

    public init(file: String, tree: SourceFileSyntax) {
        self.file = file
        self.tracker = ScopeTracker(file: file)
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    /// Current scope ID.
    public var currentScope: ScopeID {
        tracker.currentScope
    }

    /// Get source location for a syntax node.
    public func location(of node: some SyntaxProtocol) -> SourceLocation {
        node.position.toSourceLocation(using: converter, file: file)
    }

    /// Get source range for a syntax node.
    public func range(of node: some SyntaxProtocol) -> SourceRange {
        node.sourceRange(using: converter, file: file)
    }

    // MARK: - Scope-Introducing Nodes

    open override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .class,
            name: node.name.text,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: ClassDeclSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .struct,
            name: node.name.text,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: StructDeclSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .enum,
            name: node.name.text,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: EnumDeclSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .protocol,
            name: node.name.text,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: ProtocolDeclSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.description.trimmingCharacters(in: .whitespaces)
        tracker.enterScope(
            kind: .extension,
            name: name,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: ExtensionDeclSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .function,
            name: node.name.text,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: FunctionDeclSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .function,
            name: "init",
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: InitializerDeclSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .closure,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: ClosureExprSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .if,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: IfExprSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .guard,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: GuardStmtSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .for,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: ForStmtSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .while,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: WhileStmtSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .switch,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: SwitchExprSyntax) {
        tracker.exitScope()
    }

    open override func visit(_ node: DoStmtSyntax) -> SyntaxVisitorContinueKind {
        tracker.enterScope(
            kind: .do,
            location: location(of: node)
        )
        return .visitChildren
    }

    open override func visitPost(_ node: DoStmtSyntax) {
        tracker.exitScope()
    }
}
