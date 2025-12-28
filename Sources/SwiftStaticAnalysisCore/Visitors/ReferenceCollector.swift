//
//  ReferenceCollector.swift
//  SwiftStaticAnalysis
//

import Foundation
import SwiftSyntax

// MARK: - Reference Collector

/// Collects all identifier references from Swift source code.
///
/// This visitor traverses the AST and extracts all references
/// to identifiers, tracking the context in which they appear.
public final class ReferenceCollector: ScopeTrackingVisitor {
    /// Collected references.
    public private(set) var references: [Reference] = []

    /// Stack tracking the current reference context.
    private var contextStack: [ReferenceContext] = [.unknown]

    private var currentContext: ReferenceContext {
        contextStack.last ?? .unknown
    }

    // MARK: - Identifier Expressions

    public override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let reference = Reference(
            identifier: node.baseName.text,
            location: location(of: node),
            scope: currentScope,
            context: currentContext
        )
        references.append(reference)

        return .visitChildren
    }

    // MARK: - Member Access

    public override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        // Track base as member access base
        if let base = node.base {
            contextStack.append(.memberAccessBase)
            walk(base)
            contextStack.removeLast()
        }

        // Track member name
        let reference = Reference(
            identifier: node.declName.baseName.text,
            location: location(of: node.declName),
            scope: currentScope,
            context: .memberAccessMember
        )
        references.append(reference)

        return .skipChildren
    }

    // MARK: - Function Calls

    public override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Track the called expression
        contextStack.append(.call)
        walk(node.calledExpression)
        contextStack.removeLast()

        // Track arguments normally
        for argument in node.arguments {
            walk(argument.expression)
        }

        return .skipChildren
    }

    // MARK: - Type Annotations

    public override func visit(_ node: TypeAnnotationSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.typeAnnotation)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    public override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let reference = Reference(
            identifier: node.name.text,
            location: location(of: node),
            scope: currentScope,
            context: currentContext == .unknown ? .typeAnnotation : currentContext
        )
        references.append(reference)

        // Visit generic arguments
        if let generics = node.genericArgumentClause {
            for arg in generics.arguments {
                walk(arg.argument)
            }
        }

        return .skipChildren
    }

    public override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // Track qualified type: Foo.Bar
        walk(node.baseType)

        let reference = Reference(
            identifier: node.name.text,
            location: location(of: node),
            scope: currentScope,
            context: .typeAnnotation,
            isQualified: true,
            qualifier: node.baseType.description.trimmingCharacters(in: .whitespaces)
        )
        references.append(reference)

        return .skipChildren
    }

    // MARK: - Inheritance

    public override func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.inheritance)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    // MARK: - Generic Constraints

    public override func visit(_ node: GenericWhereClauseSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.genericConstraint)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    // MARK: - Assignments

    public override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        // Check if this is an assignment
        if let op = node.operator.as(BinaryOperatorExprSyntax.self),
           op.operator.text == "=" {
            // Left side is write context
            contextStack.append(.write)
            walk(node.leftOperand)
            contextStack.removeLast()

            // Right side is read context
            contextStack.append(.read)
            walk(node.rightOperand)
            contextStack.removeLast()

            return .skipChildren
        }

        return .visitChildren
    }

    // MARK: - Pattern Matching

    public override func visit(_ node: ExpressionPatternSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.pattern)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    public override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        // This is a binding, not a reference
        return .skipChildren
    }

    // MARK: - Key Paths

    public override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.keyPath)
        defer { contextStack.removeLast() }
        return .visitChildren
    }

    // MARK: - Attributes

    public override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        contextStack.append(.attribute)
        defer { contextStack.removeLast() }

        if let identifier = node.attributeName.as(IdentifierTypeSyntax.self) {
            let reference = Reference(
                identifier: identifier.name.text,
                location: location(of: identifier),
                scope: currentScope,
                context: .attribute
            )
            references.append(reference)
        }

        return .visitChildren
    }

    // MARK: - Closures

    public override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        // Closure parameters create new bindings, not references
        // but captured variables are references
        return super.visit(node)
    }

    // MARK: - Conditional Binding

    public override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        // The pattern is a binding
        // The initializer is read context
        if let initializer = node.initializer {
            contextStack.append(.read)
            walk(initializer.value)
            contextStack.removeLast()
        }

        return .skipChildren
    }
}
