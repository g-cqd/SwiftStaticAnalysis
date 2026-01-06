//  DeclarationNodeFinder.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftSyntax

/// A syntax visitor that finds a declaration at a specific source location.
///
/// This visitor traverses the syntax tree and finds the declaration node
/// at or near the specified line and column position.
///
/// ## Usage
///
/// ```swift
/// let finder = DeclarationNodeFinder(targetLine: 10, targetColumn: 5)
/// finder.walk(syntaxTree)
/// if let decl = finder.foundDeclaration {
///     print("Found: \(decl)")
/// }
/// ```
public final class DeclarationNodeFinder: SyntaxVisitor {
    /// The target line number (1-indexed).
    private let targetLine: Int

    /// The target column number (1-indexed).
    private let targetColumn: Int

    /// The found declaration node, if any.
    public private(set) var foundDeclaration: Syntax?

    /// The converter for source locations.
    private var converter: SourceLocationConverter?

    /// Creates a new declaration node finder.
    ///
    /// - Parameters:
    ///   - targetLine: The line number to search for (1-indexed).
    ///   - targetColumn: The column number to search for (1-indexed).
    public init(targetLine: Int, targetColumn: Int) {
        self.targetLine = targetLine
        self.targetColumn = targetColumn
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Visitor Methods

    public override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        converter = SourceLocationConverter(fileName: "", tree: node)
        return .visitChildren
    }

    public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: PrecedenceGroupDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    public override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkAndStore(Syntax(node))
        return .visitChildren
    }

    // MARK: - Private

    /// Checks if a node matches the target location and stores it if so.
    private func checkAndStore(_ node: Syntax) {
        guard let converter else { return }

        let location = node.startLocation(converter: converter)

        // Check if this declaration starts at the target line
        if location.line == targetLine {
            // If we already have a match, prefer the one closer to the target column
            if let existing = foundDeclaration {
                let existingLoc = existing.startLocation(converter: converter)
                if abs(location.column - targetColumn) < abs(existingLoc.column - targetColumn) {
                    foundDeclaration = node
                }
            } else {
                foundDeclaration = node
            }
        }
    }
}
