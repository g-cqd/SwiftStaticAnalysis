//  ScopeNodeFinder.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftSyntax

/// A syntax visitor that finds the innermost scope containing a source location.
///
/// This visitor traverses the syntax tree and tracks all scopes that contain
/// the target position, returning the innermost one (most specific scope).
///
/// ## Usage
///
/// ```swift
/// let finder = ScopeNodeFinder(targetLine: 10, targetColumn: 5)
/// finder.walk(syntaxTree)
/// if let scope = finder.innermostScope {
///     print("In scope: \(scope)")
/// }
/// ```
///
/// ## Scope Hierarchy
///
/// The finder tracks nested scopes and returns the innermost:
/// - File (implicit)
/// - Type (class, struct, enum, protocol, actor, extension)
/// - Function/Method
/// - Closure
public final class ScopeNodeFinder: SourceLocationSyntaxVisitor {
    /// The innermost scope containing the target position.
    public private(set) var innermostScope: Syntax?

    /// Stack of all scopes containing the target (outermost to innermost).
    public private(set) var scopeStack: [Syntax] = []

    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: ClassDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: StructDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: EnumDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: ProtocolDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: ExtensionDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: ActorDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: FunctionDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: InitializerDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: DeinitializerDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: SubscriptDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: ClosureExprSyntax) {
        popIfCurrent(Syntax(node))
    }

    public override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        checkScope(Syntax(node))
    }

    public override func visitPost(_ node: AccessorDeclSyntax) {
        popIfCurrent(Syntax(node))
    }

    // MARK: - Private

    /// Checks if the target position is within the node and pushes it to the scope stack.
    private func checkScope(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if containsTarget(node) {
            scopeStack.append(node)
            innermostScope = node
            return .visitChildren
        }

        // If we're past the target, no need to continue
        if isPastTarget(node) {
            return .skipChildren
        }

        return .visitChildren
    }

    /// Pops the scope from the stack if it's the current innermost scope.
    private func popIfCurrent(_ node: Syntax) {
        if scopeStack.last?.id == node.id {
            scopeStack.removeLast()
            innermostScope = scopeStack.last
        }
    }
}

// MARK: - Scope Information

extension ScopeNodeFinder {
    /// The containing type (class, struct, enum, etc.) if any.
    public var containingType: Syntax? {
        scopeStack.first { node in
            switch node.as(SyntaxEnum.self) {
            case .classDecl, .structDecl, .enumDecl, .protocolDecl, .extensionDecl, .actorDecl:
                return true
            default:
                return false
            }
        }
    }

    /// The containing function/method if any.
    public var containingFunction: Syntax? {
        scopeStack.first { node in
            switch node.as(SyntaxEnum.self) {
            case .functionDecl, .initializerDecl, .deinitializerDecl, .subscriptDecl:
                return true
            default:
                return false
            }
        }
    }

    /// The name of the containing type, if any.
    public var containingTypeName: String? {
        guard let typeNode = containingType else { return nil }

        switch typeNode.as(SyntaxEnum.self) {
        case .classDecl(let decl):
            return decl.name.text
        case .structDecl(let decl):
            return decl.name.text
        case .enumDecl(let decl):
            return decl.name.text
        case .protocolDecl(let decl):
            return decl.name.text
        case .extensionDecl(let decl):
            return decl.extendedType.trimmedDescription
        case .actorDecl(let decl):
            return decl.name.text
        default:
            return nil
        }
    }

    /// The name of the containing function, if any.
    public var containingFunctionName: String? {
        guard let funcNode = containingFunction else { return nil }

        switch funcNode.as(SyntaxEnum.self) {
        case .functionDecl(let decl):
            return decl.name.text
        case .initializerDecl:
            return "init"
        case .deinitializerDecl:
            return "deinit"
        case .subscriptDecl:
            return "subscript"
        default:
            return nil
        }
    }
}
