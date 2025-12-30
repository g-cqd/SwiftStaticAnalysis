//
//  ClosureNormalizer.swift
//  SwiftStaticAnalysis
//
//  Normalizes closure expressions for clone detection.
//  Handles trailing closures, shorthand argument names,
//  and other syntactic variations.
//

import RegexBuilder
import SwiftSyntax

// MARK: - Compile-Time Regex Patterns

/// Matches string literals: "anything"
/// Safe as global constant - regex is immutable after initialization.
private nonisolated(unsafe) let stringLiteralRegex = Regex {
    "\""
    ZeroOrMore {
        CharacterClass.anyOf("\"").inverted
    }
    "\""
}

/// Matches numeric literals: integers (123) and floats (123.456)
/// Safe as global constant - regex is immutable after initialization.
private nonisolated(unsafe) let numericLiteralRegex = Regex {
    Anchor.wordBoundary
    OneOrMore(.digit)
    Optionally {
        "."
        OneOrMore(.digit)
    }
    Anchor.wordBoundary
}

/// Matches shorthand parameters: $0, $1, $2, etc.
/// Safe as global constant - regex is immutable after initialization.
private nonisolated(unsafe) let shorthandParameterRegex = Regex {
    "$"
    OneOrMore(.digit)
}

// MARK: - String Normalization Utilities

extension String {
    /// Normalize string and numeric literals for clone detection.
    func normalizingLiterals() -> String {
        replacing(stringLiteralRegex, with: "\"$STR\"")
            .replacing(numericLiteralRegex, with: "$NUM")
    }

    /// Normalize shorthand parameters ($0, $1, etc.) to canonical form.
    func normalizingShorthandParameters() -> String {
        replacing(shorthandParameterRegex, with: "$X")
    }
}

// MARK: - ClosureForm

/// The syntactic form of a closure.
public enum ClosureForm: String, Sendable, Codable {
    case trailingClosure // foo { ... }
    case parenthesizedArgument // foo({ ... })
    case multipleTrailingClosures // foo { } bar: { }
}

// MARK: - NormalizedClosure

/// A normalized representation of a closure expression.
public struct NormalizedClosure: Sendable, Hashable {
    /// The normalized parameter representation.
    public let parameters: [NormalizedParameter]

    /// The normalized body structure.
    public let bodyStructure: NormalizedClosureBody

    /// Whether the closure captures anything.
    public let hasCaptures: Bool

    /// The original form of the closure.
    public let originalForm: ClosureForm

    /// Hash for comparison.
    public var contentHash: Int {
        var hasher = Hasher()
        for param in parameters {
            hasher.combine(param)
        }
        hasher.combine(bodyStructure)
        hasher.combine(hasCaptures)
        return hasher.finalize()
    }
}

// MARK: - NormalizedParameter

/// A normalized closure parameter.
public struct NormalizedParameter: Sendable, Hashable {
    /// Normalized identifier (e.g., "$0", "$1" or "param_0", "param_1").
    public let normalizedName: String

    /// Whether the parameter has an explicit type annotation.
    public let hasTypeAnnotation: Bool

    /// Index in the parameter list.
    public let index: Int
}

// MARK: - NormalizedClosureBody

/// Normalized representation of a closure body.
public struct NormalizedClosureBody: Sendable, Hashable {
    public enum BodyKind: String, Sendable, Hashable {
        case expression // Single expression
        case multiStatement // Multiple statements
        case empty // Empty closure
    }

    /// The kind of body.
    public let kind: BodyKind

    /// Normalized content fingerprint.
    public let contentFingerprint: String

    /// Number of statements.
    public let statementCount: Int

    /// Whether it's a single expression (implicit return).
    public let isSingleExpression: Bool
}

// MARK: - ClosureNormalizer

/// Normalizes closures for clone detection.
public struct ClosureNormalizer: Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    // MARK: - Normalization

    /// Normalize a closure expression.
    ///
    /// - Parameters:
    ///   - closure: The closure to normalize.
    ///   - form: The syntactic form of the closure.
    /// - Returns: Normalized closure representation.
    public func normalize(
        _ closure: ClosureExprSyntax,
        form: ClosureForm = .trailingClosure,
    ) -> NormalizedClosure {
        let parameters = normalizeParameters(closure)
        let body = normalizeBody(closure)
        let hasCaptures = closure.signature?.capture != nil

        return NormalizedClosure(
            parameters: parameters,
            bodyStructure: body,
            hasCaptures: hasCaptures,
            originalForm: form,
        )
    }

    /// Detect the form of a closure in a function call.
    ///
    /// - Parameter call: The function call containing the closure.
    /// - Returns: The form of the trailing closure, if any.
    public func detectClosureForm(in call: FunctionCallExprSyntax) -> ClosureForm? {
        if call.trailingClosure != nil {
            if !call.additionalTrailingClosures.isEmpty {
                return .multipleTrailingClosures
            }
            return .trailingClosure
        }

        // Check for parenthesized closure argument
        for arg in call.arguments where arg.expression.is(ClosureExprSyntax.self) {
            return .parenthesizedArgument
        }

        return nil
    }

    /// Check if two closures are semantically equivalent.
    ///
    /// - Parameters:
    ///   - closure1: First closure.
    ///   - closure2: Second closure.
    /// - Returns: True if semantically equivalent.
    public func areSemanticallyEquivalent(
        _ closure1: ClosureExprSyntax,
        _ closure2: ClosureExprSyntax,
    ) -> Bool {
        let norm1 = normalize(closure1)
        let norm2 = normalize(closure2)

        // Parameters must match
        guard norm1.parameters.count == norm2.parameters.count else { return false }

        // Body structure must match
        guard norm1.bodyStructure.kind == norm2.bodyStructure.kind else { return false }
        guard norm1.bodyStructure.statementCount == norm2.bodyStructure.statementCount else { return false }

        // Content fingerprint must match
        return norm1.bodyStructure.contentFingerprint == norm2.bodyStructure.contentFingerprint
    }

    // MARK: Private

    // MARK: - Parameter Normalization

    /// Normalize closure parameters.
    private func normalizeParameters(_ closure: ClosureExprSyntax) -> [NormalizedParameter] {
        var parameters: [NormalizedParameter] = []

        if let signature = closure.signature {
            // Has explicit signature
            if let params = signature.parameterClause {
                switch params {
                case let .simpleInput(identifiers):
                    // { a, b in ... }
                    for index in 0 ..< identifiers.count {
                        parameters.append(NormalizedParameter(
                            normalizedName: "param_\(index)",
                            hasTypeAnnotation: false,
                            index: index,
                        ))
                    }

                case let .parameterClause(parameterClause):
                    // { (a: Int, b: String) in ... }
                    for (index, param) in parameterClause.parameters.enumerated() {
                        parameters.append(NormalizedParameter(
                            normalizedName: "param_\(index)",
                            hasTypeAnnotation: param.type != nil,
                            index: index,
                        ))
                    }
                }
            }
        } else {
            // Infer parameter count from shorthand usage
            let count = inferShorthandParameterCount(closure)
            for index in 0 ..< count {
                parameters.append(NormalizedParameter(
                    normalizedName: "$\(index)",
                    hasTypeAnnotation: false,
                    index: index,
                ))
            }
        }

        return parameters
    }

    /// Infer the number of shorthand parameters used.
    private func inferShorthandParameterCount(_ closure: ClosureExprSyntax) -> Int {
        let visitor = ShorthandParameterVisitor()
        visitor.walk(closure)
        return visitor.maxParameterIndex + 1
    }

    // MARK: - Body Normalization

    /// Normalize closure body.
    private func normalizeBody(_ closure: ClosureExprSyntax) -> NormalizedClosureBody {
        let statements = closure.statements

        if statements.isEmpty {
            return NormalizedClosureBody(
                kind: .empty,
                contentFingerprint: "empty",
                statementCount: 0,
                isSingleExpression: false,
            )
        }

        let isSingleExpression: Bool = if statements.count == 1, let firstStatement = statements.first {
            !firstStatement.item.is(ReturnStmtSyntax.self)
        } else {
            false
        }

        let kind: NormalizedClosureBody.BodyKind = statements.count == 1 ? .expression : .multiStatement

        let fingerprint = computeBodyFingerprint(statements)

        return NormalizedClosureBody(
            kind: kind,
            contentFingerprint: fingerprint,
            statementCount: statements.count,
            isSingleExpression: isSingleExpression,
        )
    }

    /// Compute a fingerprint for the closure body.
    private func computeBodyFingerprint(_ statements: CodeBlockItemListSyntax) -> String {
        var fingerprint = ""

        for statement in statements {
            let normalized = normalizeStatement(statement.item)
            fingerprint += normalized + ";"
        }

        return fingerprint
    }

    /// Normalize a statement for fingerprinting.
    private func normalizeStatement(_ item: CodeBlockItemSyntax.Item) -> String {
        item.trimmedDescription
            .normalizingShorthandParameters()
            .normalizingLiterals()
    }
}

// MARK: - ShorthandParameterVisitor

/// Finds the highest shorthand parameter index used in a closure.
private final class ShorthandParameterVisitor: SyntaxVisitor {
    // MARK: Lifecycle

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Internal

    var maxParameterIndex: Int = -1

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text

        // Check for shorthand parameter syntax $0, $1, etc.
        if name.hasPrefix("$"), let index = Int(name.dropFirst()) {
            maxParameterIndex = max(maxParameterIndex, index)
        }

        return .visitChildren
    }
}

// MARK: - ClosureEquivalenceChecker

/// Checks if closures are equivalent despite syntactic differences.
public struct ClosureEquivalenceChecker: Sendable {
    // MARK: Lifecycle

    public init() {
        normalizer = ClosureNormalizer()
    }

    // MARK: Public

    /// Check if two function calls with closures are equivalent.
    ///
    /// This handles cases like:
    /// - `items.map { $0 * 2 }` vs `items.map({ $0 * 2 })`
    /// - `items.map { x in x * 2 }` vs `items.map { $0 * 2 }`
    ///
    /// - Returns: True if equivalent.
    public func areEquivalent(
        _ call1: FunctionCallExprSyntax,
        _ call2: FunctionCallExprSyntax,
    ) -> Bool {
        // Get closures from both calls
        guard let closure1 = extractClosure(from: call1),
              let closure2 = extractClosure(from: call2)
        else {
            return false
        }

        return normalizer.areSemanticallyEquivalent(closure1, closure2)
    }

    // MARK: Private

    private let normalizer: ClosureNormalizer

    /// Extract the primary closure from a function call.
    private func extractClosure(from call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        // Check trailing closure
        if let trailing = call.trailingClosure {
            return trailing
        }

        // Check argument closures
        for arg in call.arguments {
            if let closure = arg.expression.as(ClosureExprSyntax.self) {
                return closure
            }
        }

        return nil
    }
}

// MARK: - FunctionCallNormalizer

/// Normalizes function calls with closures to a canonical form.
public struct FunctionCallNormalizer: Sendable {
    // MARK: Lifecycle

    public init() {
        closureNormalizer = ClosureNormalizer()
    }

    // MARK: Public

    /// Normalize a function call for clone detection.
    ///
    /// - Parameter call: The function call to normalize.
    /// - Returns: Normalized representation string.
    public func normalize(_ call: FunctionCallExprSyntax) -> String {
        var result = ""

        // Get the callee
        result += normalizeCallee(call.calledExpression)

        // Normalize arguments
        result += "("
        var args: [String] = []

        for arg in call.arguments {
            if let closure = arg.expression.as(ClosureExprSyntax.self) {
                let normalized = closureNormalizer.normalize(closure, form: .parenthesizedArgument)
                args.append("closure[\(normalized.parameters.count)]")
            } else {
                args.append(normalizeArgument(arg))
            }
        }

        // Add trailing closure if present
        if let trailing = call.trailingClosure {
            let normalized = closureNormalizer.normalize(trailing, form: .trailingClosure)
            args.append("trailing[\(normalized.parameters.count)]")
        }

        result += args.joined(separator: ", ")
        result += ")"

        return result
    }

    // MARK: Private

    private let closureNormalizer: ClosureNormalizer

    /// Normalize the callee expression.
    private func normalizeCallee(_ expr: ExprSyntax) -> String {
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            let member = memberAccess.declName.baseName.text
            if let base = memberAccess.base {
                return normalizeCallee(base) + "." + member
            }
            return member
        }

        if let declRef = expr.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text
        }

        return expr.trimmedDescription
    }

    /// Normalize an argument.
    private func normalizeArgument(_ arg: LabeledExprSyntax) -> String {
        let label = arg.label?.text ?? ""
        let value = normalizeValue(arg.expression)

        if label.isEmpty {
            return value
        }
        return "\(label): \(value)"
    }

    /// Normalize an expression value.
    private func normalizeValue(_ expr: ExprSyntax) -> String {
        // Replace literals with placeholders
        if expr.is(StringLiteralExprSyntax.self) {
            return "$STR"
        }
        if expr.is(IntegerLiteralExprSyntax.self) ||
            expr.is(FloatLiteralExprSyntax.self) {
            return "$NUM"
        }
        if expr.is(BooleanLiteralExprSyntax.self) {
            return "$BOOL"
        }

        return expr.trimmedDescription
    }
}
