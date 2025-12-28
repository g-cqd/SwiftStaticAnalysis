//
//  ResultBuilderAnalyzer.swift
//  SwiftStaticAnalysis
//
//  Detects and analyzes result builder usage in Swift code.
//  Result builders like @ViewBuilder transform closure contents
//  into builder method calls, which affects clone detection.
//

import Foundation
import SwiftSyntax

// MARK: - Result Builder Type

/// Known result builder types in Swift/SwiftUI.
public enum ResultBuilderType: String, Sendable, Codable, CaseIterable {
    // SwiftUI builders
    case viewBuilder = "ViewBuilder"
    case commandsBuilder = "CommandsBuilder"
    case sceneBuilder = "SceneBuilder"
    case toolbarContentBuilder = "ToolbarContentBuilder"
    case accessibilityRotorContentBuilder = "AccessibilityRotorContentBuilder"
    case tableColumnBuilder = "TableColumnBuilder"
    case tableRowBuilder = "TableRowBuilder"

    // Swift standard library
    case arrayBuilder = "ArrayBuilder"
    case stringInterpolation = "StringInterpolation"

    // RegexBuilder
    case regexComponentBuilder = "RegexComponentBuilder"

    // Custom/unknown builder
    case custom

    /// Whether this is a SwiftUI-specific builder.
    public var isSwiftUI: Bool {
        switch self {
        case .viewBuilder, .commandsBuilder, .sceneBuilder,
             .toolbarContentBuilder, .accessibilityRotorContentBuilder,
             .tableColumnBuilder, .tableRowBuilder:
            return true
        default:
            return false
        }
    }

    /// Infer builder type from attribute name.
    public static func from(attributeName: String) -> ResultBuilderType? {
        // Check if it's a known builder
        for type in ResultBuilderType.allCases where type != .custom {
            if attributeName == type.rawValue || attributeName.hasSuffix(".\(type.rawValue)") {
                return type
            }
        }

        // Check for common builder patterns
        if attributeName.hasSuffix("Builder") {
            return .custom
        }

        return nil
    }
}

// MARK: - Normalized Closure

/// A normalized representation of a result builder closure.
public struct NormalizedResultBuilderClosure: Sendable, Hashable {
    /// The builder type.
    public let builderType: ResultBuilderType

    /// Normalized statements (semantic content).
    public let statements: [NormalizedStatement]

    /// Original source range.
    public let startLine: Int
    public let endLine: Int
    public let file: String

    /// Hash for comparison.
    public var contentHash: Int {
        var hasher = Hasher()
        hasher.combine(builderType)
        for stmt in statements {
            hasher.combine(stmt)
        }
        return hasher.finalize()
    }
}

/// A normalized statement within a result builder.
public struct NormalizedStatement: Sendable, Hashable {
    /// The type of statement.
    public let kind: StatementKind

    /// Normalized content (type names, identifiers normalized).
    public let normalizedContent: String

    /// Child statements (for control flow).
    public let children: [NormalizedStatement]

    public enum StatementKind: String, Sendable, Hashable {
        case expression
        case ifStatement
        case switchStatement
        case forLoop
        case binding // let/var
        case viewModifier
        case other
    }
}

// MARK: - Result Builder Context

/// Context information for result builder detection.
public struct ResultBuilderContext: Sendable {
    /// The containing declaration name (e.g., "body" property).
    public let declarationName: String?

    /// The containing type name.
    public let typeName: String?

    /// Attributes on the declaration.
    public let attributes: [String]

    /// Whether the containing type conforms to known protocols.
    public let conformances: [String]

    /// Check if the context has a specific attribute.
    public func hasAttribute(_ name: String) -> Bool {
        attributes.contains(name) || attributes.contains("@\(name)")
    }

    /// Check if it conforms to a protocol.
    public func conformsTo(_ protocolName: String) -> Bool {
        conformances.contains(protocolName)
    }
}

// MARK: - Result Builder Analyzer

/// Analyzes result builder usage in Swift code.
public struct ResultBuilderAnalyzer: Sendable {

    public init() {}

    // MARK: - Convenience Methods

    /// Try to detect and normalize a closure as a result builder.
    /// This is a convenience method for simple detection without full context.
    ///
    /// - Parameter closure: The closure to analyze.
    /// - Returns: Normalized closure if it's a result builder, nil otherwise.
    public func normalizeClosure(_ closure: ClosureExprSyntax) -> NormalizedResultBuilderClosure? {
        // Simple heuristic detection
        guard appearsToBeResultBuilder(closure) else { return nil }

        // Default to ViewBuilder if it looks like a result builder
        let builderType: ResultBuilderType = .viewBuilder
        let statements = normalizeStatements(closure.statements)

        return NormalizedResultBuilderClosure(
            builderType: builderType,
            statements: statements,
            startLine: 0,
            endLine: 0,
            file: ""
        )
    }

    // MARK: - Detection

    /// Detect if a closure uses a result builder.
    ///
    /// - Parameters:
    ///   - closure: The closure expression to analyze.
    ///   - context: Context about the surrounding code.
    /// - Returns: The detected builder type, or nil.
    public func detectResultBuilder(
        in closure: ClosureExprSyntax,
        context: ResultBuilderContext
    ) -> ResultBuilderType? {
        // Check explicit attributes first
        for attr in context.attributes {
            if let builderType = ResultBuilderType.from(attributeName: attr) {
                return builderType
            }
        }

        // Check if it's a View body
        if context.declarationName == "body" && context.conformsTo("View") {
            return .viewBuilder
        }

        // Heuristic: check for result builder patterns
        if appearsToBeResultBuilder(closure) {
            return inferBuilderType(from: context)
        }

        return nil
    }

    /// Detect result builder type from a function/property declaration.
    ///
    /// - Parameter decl: The declaration to analyze.
    /// - Returns: The builder type if detected.
    public func detectResultBuilder(in decl: some DeclSyntaxProtocol) -> ResultBuilderType? {
        // Check attributes on the declaration
        if let funcDecl = decl.as(FunctionDeclSyntax.self) {
            for attribute in funcDecl.attributes {
                if let attrName = extractAttributeName(attribute),
                   let builderType = ResultBuilderType.from(attributeName: attrName) {
                    return builderType
                }
            }
        }

        if let varDecl = decl.as(VariableDeclSyntax.self) {
            for attribute in varDecl.attributes {
                if let attrName = extractAttributeName(attribute),
                   let builderType = ResultBuilderType.from(attributeName: attrName) {
                    return builderType
                }
            }
        }

        return nil
    }

    // MARK: - Normalization

    /// Normalize a result builder closure for clone comparison.
    ///
    /// - Parameters:
    ///   - closure: The closure to normalize.
    ///   - builderType: The detected builder type.
    ///   - file: Source file path.
    ///   - converter: Source location converter.
    /// - Returns: Normalized closure representation.
    public func normalize(
        _ closure: ClosureExprSyntax,
        builderType: ResultBuilderType,
        file: String,
        converter: SourceLocationConverter
    ) -> NormalizedResultBuilderClosure {
        let statements = normalizeStatements(closure.statements)

        let startLoc = converter.location(for: closure.positionAfterSkippingLeadingTrivia)
        let endLoc = converter.location(for: closure.endPositionBeforeTrailingTrivia)

        return NormalizedResultBuilderClosure(
            builderType: builderType,
            statements: statements,
            startLine: startLoc.line,
            endLine: endLoc.line,
            file: file
        )
    }

    // MARK: - Private Helpers

    /// Check if a closure appears to use result builder syntax.
    private func appearsToBeResultBuilder(_ closure: ClosureExprSyntax) -> Bool {
        let statements = closure.statements

        // Empty closures aren't result builders
        guard statements.count > 0 else { return false }

        // Single expression with return is normal
        if statements.count == 1 {
            if statements.first?.item.is(ReturnStmtSyntax.self) == true {
                return false
            }
        }

        // Multiple expressions without explicit return suggest result builder
        var hasExplicitReturn = false
        var expressionCount = 0

        for statement in statements {
            if statement.item.is(ReturnStmtSyntax.self) {
                hasExplicitReturn = true
            }
            if statement.item.is(ExpressionStmtSyntax.self) ||
               statement.item.is(FunctionCallExprSyntax.self) {
                expressionCount += 1
            }
        }

        // Multiple expressions without return = likely result builder
        return expressionCount > 1 && !hasExplicitReturn
    }

    /// Infer builder type from context.
    private func inferBuilderType(from context: ResultBuilderContext) -> ResultBuilderType? {
        // Check conformances
        if context.conformsTo("View") || context.conformsTo("App") || context.conformsTo("Scene") {
            if context.declarationName == "body" {
                if context.conformsTo("App") {
                    return .sceneBuilder
                }
                return .viewBuilder
            }
            if context.declarationName == "commands" {
                return .commandsBuilder
            }
        }

        if context.conformsTo("Commands") {
            return .commandsBuilder
        }

        if context.conformsTo("ToolbarContent") {
            return .toolbarContentBuilder
        }

        return nil
    }

    /// Extract attribute name from an attribute element.
    private func extractAttributeName(_ attribute: AttributeListSyntax.Element) -> String? {
        switch attribute {
        case .attribute(let attr):
            return attr.attributeName.trimmedDescription
        case .ifConfigDecl:
            return nil
        }
    }

    /// Normalize statements in a code block.
    private func normalizeStatements(_ statements: CodeBlockItemListSyntax) -> [NormalizedStatement] {
        var normalized: [NormalizedStatement] = []

        for statement in statements {
            if let normalizedStmt = normalizeStatement(statement.item) {
                normalized.append(normalizedStmt)
            }
        }

        return normalized
    }

    /// Normalize a single statement.
    private func normalizeStatement(_ item: CodeBlockItemSyntax.Item) -> NormalizedStatement? {
        // Handle different statement types
        if let ifStmt = item.as(IfExprSyntax.self) {
            return normalizeIfStatement(ifStmt)
        }

        if let switchStmt = item.as(SwitchExprSyntax.self) {
            return normalizeSwitchStatement(switchStmt)
        }

        if let forStmt = item.as(ForStmtSyntax.self) {
            return normalizeForStatement(forStmt)
        }

        if let varDecl = item.as(VariableDeclSyntax.self) {
            return NormalizedStatement(
                kind: .binding,
                normalizedContent: normalizeVariableDecl(varDecl),
                children: []
            )
        }

        // Expression statements (views, etc.)
        if let expr = item.as(ExpressionStmtSyntax.self) {
            return NormalizedStatement(
                kind: .expression,
                normalizedContent: normalizeExpression(expr.expression),
                children: []
            )
        }

        // Fallback for direct expressions
        if let funcCall = item.as(FunctionCallExprSyntax.self) {
            return NormalizedStatement(
                kind: .expression,
                normalizedContent: normalizeFunctionCall(funcCall),
                children: []
            )
        }

        return nil
    }

    /// Normalize an if statement.
    private func normalizeIfStatement(_ ifStmt: IfExprSyntax) -> NormalizedStatement {
        var children: [NormalizedStatement] = []

        // Normalize body
        children.append(contentsOf: normalizeStatements(ifStmt.body.statements))

        // Normalize else clause if present
        if let elseClause = ifStmt.elseBody {
            switch elseClause {
            case .codeBlock(let block):
                children.append(contentsOf: normalizeStatements(block.statements))
            case .ifExpr(let elseIf):
                if let normalized = normalizeIfStatement(elseIf) as NormalizedStatement? {
                    children.append(normalized)
                }
            }
        }

        return NormalizedStatement(
            kind: .ifStatement,
            normalizedContent: "if",
            children: children
        )
    }

    /// Normalize a switch statement.
    private func normalizeSwitchStatement(_ switchStmt: SwitchExprSyntax) -> NormalizedStatement {
        var children: [NormalizedStatement] = []

        for caseItem in switchStmt.cases {
            if case .switchCase(let switchCase) = caseItem {
                children.append(contentsOf: normalizeStatements(switchCase.statements))
            }
        }

        return NormalizedStatement(
            kind: .switchStatement,
            normalizedContent: "switch",
            children: children
        )
    }

    /// Normalize a for statement.
    private func normalizeForStatement(_ forStmt: ForStmtSyntax) -> NormalizedStatement {
        let bodyStatements = normalizeStatements(forStmt.body.statements)

        return NormalizedStatement(
            kind: .forLoop,
            normalizedContent: "for",
            children: bodyStatements
        )
    }

    /// Normalize a variable declaration.
    private func normalizeVariableDecl(_ varDecl: VariableDeclSyntax) -> String {
        let keyword = varDecl.bindingSpecifier.text
        let bindings = varDecl.bindings.map { $0.pattern.trimmedDescription }
        return "\(keyword) \(bindings.joined(separator: ", "))"
    }

    /// Normalize an expression to a canonical form.
    private func normalizeExpression(_ expr: ExprSyntax) -> String {
        // For function calls, extract the base call
        if let funcCall = expr.as(FunctionCallExprSyntax.self) {
            return normalizeFunctionCall(funcCall)
        }

        // For member access chains (view modifiers), normalize
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            return normalizeMemberAccess(memberAccess)
        }

        // Generic normalization
        return normalizeGenericExpression(expr)
    }

    /// Normalize a function call.
    private func normalizeFunctionCall(_ call: FunctionCallExprSyntax) -> String {
        let callee = call.calledExpression.trimmedDescription
        let argCount = call.arguments.count
        return "\(callee)(\(argCount) args)"
    }

    /// Normalize member access (view modifier chains).
    private func normalizeMemberAccess(_ access: MemberAccessExprSyntax) -> String {
        var chain: [String] = []
        var current: ExprSyntax = ExprSyntax(access)

        while let memberAccess = current.as(MemberAccessExprSyntax.self) {
            chain.insert(memberAccess.declName.baseName.text, at: 0)
            if let base = memberAccess.base {
                current = base
            } else {
                break
            }
        }

        // Add the base
        if let funcCall = current.as(FunctionCallExprSyntax.self) {
            chain.insert(normalizeFunctionCall(funcCall), at: 0)
        } else {
            chain.insert(current.trimmedDescription, at: 0)
        }

        return chain.joined(separator: ".")
    }

    /// Generic expression normalization.
    private func normalizeGenericExpression(_ expr: ExprSyntax) -> String {
        // Remove literals, keep structure
        var normalized = expr.trimmedDescription

        // Replace string literals
        normalized = normalized.replacingOccurrences(
            of: #""[^"]*""#,
            with: "\"$STR\"",
            options: .regularExpression
        )

        // Replace numeric literals
        normalized = normalized.replacingOccurrences(
            of: #"\b\d+(\.\d+)?\b"#,
            with: "$NUM",
            options: .regularExpression
        )

        return normalized
    }
}

// MARK: - Result Builder Visitor

/// Visits a syntax tree to find all result builder closures.
public final class ResultBuilderVisitor: SyntaxVisitor {
    /// Detected result builder closures.
    public private(set) var builders: [ResultBuilderInfo] = []

    /// The analyzer to use.
    private let analyzer: ResultBuilderAnalyzer

    /// Source file path.
    private let file: String

    /// Source location converter.
    private let converter: SourceLocationConverter

    /// Current context stack.
    private var contextStack: [ResultBuilderContext] = []

    /// Info about a detected result builder.
    public struct ResultBuilderInfo {
        public let type: ResultBuilderType
        public let closure: NormalizedResultBuilderClosure
        public let declarationName: String?
        public let typeName: String?
    }

    public init(file: String, tree: SourceFileSyntax) {
        self.analyzer = ResultBuilderAnalyzer()
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Visit Methods

    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let conformances = node.inheritanceClause?.inheritedTypes.map {
            $0.type.trimmedDescription
        } ?? []

        let attributes = node.attributes.compactMap { attr -> String? in
            if case .attribute(let a) = attr {
                return a.attributeName.trimmedDescription
            }
            return nil
        }

        let context = ResultBuilderContext(
            declarationName: nil,
            typeName: node.name.text,
            attributes: attributes,
            conformances: conformances
        )

        contextStack.append(context)
        return .visitChildren
    }

    public override func visitPost(_ node: StructDeclSyntax) {
        contextStack.removeLast()
    }

    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let conformances = node.inheritanceClause?.inheritedTypes.map {
            $0.type.trimmedDescription
        } ?? []

        let attributes = node.attributes.compactMap { attr -> String? in
            if case .attribute(let a) = attr {
                return a.attributeName.trimmedDescription
            }
            return nil
        }

        let context = ResultBuilderContext(
            declarationName: nil,
            typeName: node.name.text,
            attributes: attributes,
            conformances: conformances
        )

        contextStack.append(context)
        return .visitChildren
    }

    public override func visitPost(_ node: ClassDeclSyntax) {
        contextStack.removeLast()
    }

    public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.bindings.first?.pattern.trimmedDescription

        let attributes = node.attributes.compactMap { attr -> String? in
            if case .attribute(let a) = attr {
                return a.attributeName.trimmedDescription
            }
            return nil
        }

        let parentContext = contextStack.last
        let context = ResultBuilderContext(
            declarationName: name,
            typeName: parentContext?.typeName,
            attributes: attributes + (parentContext?.attributes ?? []),
            conformances: parentContext?.conformances ?? []
        )

        contextStack.append(context)
        return .visitChildren
    }

    public override func visitPost(_ node: VariableDeclSyntax) {
        contextStack.removeLast()
    }

    public override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        guard let context = contextStack.last else {
            return .visitChildren
        }

        if let builderType = analyzer.detectResultBuilder(in: node, context: context) {
            let normalized = analyzer.normalize(
                node,
                builderType: builderType,
                file: file,
                converter: converter
            )

            builders.append(ResultBuilderInfo(
                type: builderType,
                closure: normalized,
                declarationName: context.declarationName,
                typeName: context.typeName
            ))
        }

        return .visitChildren
    }
}
