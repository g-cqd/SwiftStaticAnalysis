//
//  DeclarationCollector.swift
//  SwiftStaticAnalysis
//

import Foundation
import SwiftSyntax

// MARK: - Declaration Collector

/// Collects all declarations from Swift source code.
///
/// This visitor traverses the AST and extracts all declarations
/// including functions, variables, types, and imports.
public final class DeclarationCollector: ScopeTrackingVisitor {
    /// Collected declarations.
    public private(set) var declarations: [Declaration] = []

    /// Collected imports.
    public private(set) var imports: [Declaration] = []

    // MARK: - Functions

    public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: isInTypeContext ? .method : .function,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        // Let parent handle scope tracking
        return super.visit(node)
    }

    // MARK: - Initializers

    public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: "init",
            kind: .initializer,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    // MARK: - Deinitializers

    public override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: "deinit",
            kind: .deinitializer,
            modifiers: node.modifiers,
            node: node
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Variables

    public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isConstant = node.bindingSpecifier.tokenKind == .keyword(.let)

        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }

            let typeAnnotation = binding.typeAnnotation?.type.description
                .trimmingCharacters(in: .whitespaces)

            let declaration = makeDeclaration(
                name: identifier.identifier.text,
                kind: isConstant ? .constant : .variable,
                modifiers: node.modifiers,
                node: node,
                typeAnnotation: typeAnnotation,
                documentation: extractDocumentation(from: node)
            )
            declarations.append(declaration)
        }

        return .visitChildren
    }

    // MARK: - Function Parameters

    public override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = node.secondName?.text ?? node.firstName.text
        let typeAnnotation = node.type.description.trimmingCharacters(in: .whitespaces)

        let declaration = Declaration(
            name: name,
            kind: .parameter,
            accessLevel: .private,
            modifiers: [],
            location: location(of: node),
            range: range(of: node),
            scope: currentScope,
            typeAnnotation: typeAnnotation
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Types

    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let genericParams = extractGenericParameters(from: node.genericParameterClause)

        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .class,
            modifiers: node.modifiers,
            node: node,
            genericParameters: genericParams,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let genericParams = extractGenericParameters(from: node.genericParameterClause)

        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .struct,
            modifiers: node.modifiers,
            node: node,
            genericParameters: genericParams,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    public override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let genericParams = extractGenericParameters(from: node.genericParameterClause)

        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .enum,
            modifiers: node.modifiers,
            node: node,
            genericParameters: genericParams,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    public override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .protocol,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    public override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.description.trimmingCharacters(in: .whitespaces)

        let declaration = makeDeclaration(
            name: name,
            kind: .extension,
            modifiers: node.modifiers,
            node: node
        )
        declarations.append(declaration)

        return super.visit(node)
    }

    // MARK: - Type Aliases

    public override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .typealias,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Associated Types

    public override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: node.name.text,
            kind: .associatedtype,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Enum Cases

    public override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        let declaration = Declaration(
            name: node.name.text,
            kind: .enumCase,
            accessLevel: .internal,  // Inherits from enum
            modifiers: [],
            location: location(of: node),
            range: range(of: node),
            scope: currentScope
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Subscripts

    public override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = makeDeclaration(
            name: "subscript",
            kind: .subscript,
            modifiers: node.modifiers,
            node: node,
            documentation: extractDocumentation(from: node)
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Operators

    public override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        let declaration = Declaration(
            name: node.name.text,
            kind: .operator,
            accessLevel: .internal,
            modifiers: [],
            location: location(of: node),
            range: range(of: node),
            scope: currentScope
        )
        declarations.append(declaration)

        return .visitChildren
    }

    // MARK: - Imports

    public override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let moduleName = node.path.map { $0.name.text }.joined(separator: ".")

        let declaration = Declaration(
            name: moduleName,
            kind: .import,
            accessLevel: .internal,
            modifiers: [],
            location: location(of: node),
            range: range(of: node),
            scope: .global
        )
        imports.append(declaration)

        return .visitChildren
    }

    // MARK: - Helpers

    private var isInTypeContext: Bool {
        let ancestors = tracker.tree.ancestors(of: currentScope)
        return ancestors.contains { scope in
            switch scope.kind {
            case .class, .struct, .enum, .protocol, .extension:
                return true
            default:
                return false
            }
        }
    }

    private func makeDeclaration(
        name: String,
        kind: DeclarationKind,
        modifiers: DeclModifierListSyntax,
        node: some SyntaxProtocol,
        typeAnnotation: String? = nil,
        genericParameters: [String] = [],
        documentation: String? = nil
    ) -> Declaration {
        Declaration(
            name: name,
            kind: kind,
            accessLevel: extractAccessLevel(from: modifiers),
            modifiers: extractModifiers(from: modifiers),
            location: location(of: node),
            range: range(of: node),
            scope: currentScope,
            typeAnnotation: typeAnnotation,
            genericParameters: genericParameters,
            documentation: documentation
        )
    }

    private func extractAccessLevel(from modifiers: DeclModifierListSyntax) -> AccessLevel {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.private):
                return .private
            case .keyword(.fileprivate):
                return .fileprivate
            case .keyword(.internal):
                return .internal
            case .keyword(.package):
                return .package
            case .keyword(.public):
                return .public
            case .keyword(.open):
                return .open
            default:
                continue
            }
        }
        return .internal
    }

    private func extractModifiers(from modifiers: DeclModifierListSyntax) -> DeclarationModifiers {
        var result: DeclarationModifiers = []

        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.static):
                result.insert(.static)
            case .keyword(.class):
                result.insert(.class)
            case .keyword(.final):
                result.insert(.final)
            case .keyword(.override):
                result.insert(.override)
            case .keyword(.mutating):
                result.insert(.mutating)
            case .keyword(.nonmutating):
                result.insert(.nonmutating)
            case .keyword(.lazy):
                result.insert(.lazy)
            case .keyword(.weak):
                result.insert(.weak)
            case .keyword(.unowned):
                result.insert(.unowned)
            case .keyword(.optional):
                result.insert(.optional)
            case .keyword(.required):
                result.insert(.required)
            case .keyword(.convenience):
                result.insert(.convenience)
            case .keyword(.nonisolated):
                result.insert(.nonisolated)
            case .keyword(.consuming):
                result.insert(.consuming)
            case .keyword(.borrowing):
                result.insert(.borrowing)
            default:
                continue
            }
        }

        return result
    }

    private func extractGenericParameters(from clause: GenericParameterClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.parameters.map { $0.name.text }
    }

    private func extractDocumentation(from node: some SyntaxProtocol) -> String? {
        // Look for documentation comments in leading trivia
        for piece in node.leadingTrivia {
            switch piece {
            case .docLineComment(let text):
                return String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            case .docBlockComment(let text):
                // Remove /** and */
                var cleaned = text
                if cleaned.hasPrefix("/**") {
                    cleaned = String(cleaned.dropFirst(3))
                }
                if cleaned.hasSuffix("*/") {
                    cleaned = String(cleaned.dropLast(2))
                }
                return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                continue
            }
        }
        return nil
    }
}
