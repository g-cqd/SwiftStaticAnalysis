//  SymbolContext.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore

/// Context information for a symbol match.
///
/// Contains surrounding source code, documentation, signature, and scope information
/// that can be optionally retrieved when performing symbol lookups.
///
/// ## Usage
///
/// ```swift
/// let context = try await extractor.extractContext(
///     for: match,
///     configuration: .all
/// )
/// print(context.linesBefore.map(\.content).joined(separator: "\n"))
/// print(context.documentation?.summary ?? "No docs")
/// ```
public struct SymbolContext: Sendable, Codable, Equatable {
    /// Lines of source code before the symbol definition.
    public let linesBefore: [SourceLine]

    /// Lines of source code after the symbol definition.
    public let linesAfter: [SourceLine]

    /// The containing scope (type, function, etc.) if requested.
    public let scopeContent: ScopeContent?

    /// The complete declaration signature (without body).
    public let completeSignature: String?

    /// The body of the declaration (for functions, computed properties, etc.).
    public let body: String?

    /// Parsed documentation comment if present.
    public let documentation: DocumentationComment?

    /// The raw declaration source text.
    public let declarationSource: String?

    /// Creates a new symbol context.
    public init(
        linesBefore: [SourceLine] = [],
        linesAfter: [SourceLine] = [],
        scopeContent: ScopeContent? = nil,
        completeSignature: String? = nil,
        body: String? = nil,
        documentation: DocumentationComment? = nil,
        declarationSource: String? = nil
    ) {
        self.linesBefore = linesBefore
        self.linesAfter = linesAfter
        self.scopeContent = scopeContent
        self.completeSignature = completeSignature
        self.body = body
        self.documentation = documentation
        self.declarationSource = declarationSource
    }

    /// An empty context with no information.
    public static let empty = SymbolContext()

    /// Whether this context has any data.
    public var isEmpty: Bool {
        linesBefore.isEmpty && linesAfter.isEmpty && scopeContent == nil && completeSignature == nil && body == nil
            && documentation == nil && declarationSource == nil
    }
}

// MARK: - SourceLine

/// A single line of source code with metadata.
public struct SourceLine: Sendable, Codable, Equatable, Hashable {
    /// The 1-indexed line number.
    public let lineNumber: Int

    /// The content of the line (without trailing newline).
    public let content: String

    /// Whether this line should be highlighted (e.g., the symbol definition line).
    public let isHighlighted: Bool

    /// Creates a new source line.
    public init(lineNumber: Int, content: String, isHighlighted: Bool = false) {
        self.lineNumber = lineNumber
        self.content = content
        self.isHighlighted = isHighlighted
    }
}

extension SourceLine: CustomStringConvertible {
    public var description: String {
        let prefix = isHighlighted ? ">" : " "
        return "\(prefix)\(lineNumber.formatted(.number.precision(.integerLength(4)))): \(content)"
    }

    /// Formats the line with a specific line number width.
    public func formatted(lineNumberWidth: Int = 4) -> String {
        let prefix = isHighlighted ? ">" : " "
        let paddedLineNumber = String(lineNumber).padding(
            toLength: lineNumberWidth,
            withPad: " ",
            startingAt: 0
        )
        return "\(prefix)\(paddedLineNumber): \(content)"
    }
}

// MARK: - ScopeContent

/// Content of a scope containing a symbol.
///
/// Represents the enclosing type, function, or other scope that contains
/// the symbol being looked up.
public struct ScopeContent: Sendable, Codable, Equatable {
    /// The kind of scope.
    public let kind: ContextScopeKind

    /// The name of the scope (e.g., type name, function name).
    public let name: String?

    /// The start line of the scope (1-indexed).
    public let startLine: Int

    /// The end line of the scope (1-indexed).
    public let endLine: Int

    /// The complete source text of the scope.
    public let source: String

    /// Creates a new scope content.
    public init(
        kind: ContextScopeKind,
        name: String? = nil,
        startLine: Int,
        endLine: Int,
        source: String
    ) {
        self.kind = kind
        self.name = name
        self.startLine = startLine
        self.endLine = endLine
        self.source = source
    }

    /// The number of lines in the scope.
    public var lineCount: Int {
        endLine - startLine + 1
    }
}

/// Kind of scope that can contain symbols in context extraction.
public enum ContextScopeKind: String, Sendable, Codable, Equatable, CaseIterable {
    case file
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case function
    case method
    case initializer
    case deinitializer
    case accessor
    case closure
    case actor

    /// Whether this scope kind is a type.
    public var isType: Bool {
        switch self {
        case .class, .struct, .enum, .protocol, .extension, .actor:
            return true
        default:
            return false
        }
    }

    /// Whether this scope kind is a callable.
    public var isCallable: Bool {
        switch self {
        case .function, .method, .initializer, .deinitializer, .accessor, .closure:
            return true
        default:
            return false
        }
    }
}

// MARK: - DocumentationComment

/// Parsed documentation comment for a symbol.
///
/// Supports both `///` and `/** */` style Swift documentation.
public struct DocumentationComment: Sendable, Codable, Equatable {
    /// The summary/description paragraph.
    public let summary: String?

    /// Documented parameters.
    public let parameters: [ParameterDoc]

    /// Return value documentation.
    public let returns: String?

    /// Throws documentation.
    public let `throws`: String?

    /// Additional notes.
    public let notes: [String]

    /// The raw comment text (unparsed).
    public let rawComment: String

    /// Creates a new documentation comment.
    public init(
        summary: String? = nil,
        parameters: [ParameterDoc] = [],
        returns: String? = nil,
        throws: String? = nil,
        notes: [String] = [],
        rawComment: String
    ) {
        self.summary = summary
        self.parameters = parameters
        self.returns = returns
        self.throws = `throws`
        self.notes = notes
        self.rawComment = rawComment
    }

    /// Whether this documentation has any parsed content.
    public var hasContent: Bool {
        summary != nil || !parameters.isEmpty || returns != nil || `throws` != nil || !notes.isEmpty
    }
}

/// Documentation for a single parameter.
public struct ParameterDoc: Sendable, Codable, Equatable, Hashable {
    /// The parameter name.
    public let name: String

    /// The parameter description.
    public let description: String

    /// Creates a new parameter documentation.
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

// MARK: - SymbolContextConfiguration

/// Configuration for context extraction.
///
/// Specifies which context elements to include when looking up symbols.
///
/// ## Usage
///
/// ```swift
/// // Just surrounding lines
/// let config = SymbolContextConfiguration.lines(3)
///
/// // Full context
/// let config = SymbolContextConfiguration.all
///
/// // Custom configuration
/// let config = SymbolContextConfiguration(
///     linesBefore: 5,
///     linesAfter: 5,
///     includeDocumentation: true
/// )
/// ```
public struct SymbolContextConfiguration: Sendable, Codable, Equatable {
    /// Number of lines to include before the symbol.
    public var linesBefore: Int

    /// Number of lines to include after the symbol.
    public var linesAfter: Int

    /// Whether to include the containing scope.
    public var includeScope: Bool

    /// Whether to include the complete signature.
    public var includeSignature: Bool

    /// Whether to include the declaration body.
    public var includeBody: Bool

    /// Whether to include documentation comments.
    public var includeDocumentation: Bool

    /// Creates a new configuration.
    public init(
        linesBefore: Int = 0,
        linesAfter: Int = 0,
        includeScope: Bool = false,
        includeSignature: Bool = false,
        includeBody: Bool = false,
        includeDocumentation: Bool = false
    ) {
        self.linesBefore = max(0, linesBefore)
        self.linesAfter = max(0, linesAfter)
        self.includeScope = includeScope
        self.includeSignature = includeSignature
        self.includeBody = includeBody
        self.includeDocumentation = includeDocumentation
    }

    /// Configuration with no context extraction.
    public static let none = SymbolContextConfiguration()

    /// Configuration with surrounding lines only.
    ///
    /// - Parameter count: Number of lines before and after.
    /// - Returns: A configuration for line context.
    public static func lines(_ count: Int) -> SymbolContextConfiguration {
        SymbolContextConfiguration(
            linesBefore: count,
            linesAfter: count
        )
    }

    /// Configuration with asymmetric surrounding lines.
    ///
    /// - Parameters:
    ///   - before: Number of lines before.
    ///   - after: Number of lines after.
    /// - Returns: A configuration for line context.
    public static func lines(before: Int, after: Int) -> SymbolContextConfiguration {
        SymbolContextConfiguration(
            linesBefore: before,
            linesAfter: after
        )
    }

    /// Configuration that includes all context.
    public static let all = SymbolContextConfiguration(
        linesBefore: 5,
        linesAfter: 5,
        includeScope: true,
        includeSignature: true,
        includeBody: true,
        includeDocumentation: true
    )

    /// Configuration with documentation only.
    public static let documentationOnly = SymbolContextConfiguration(
        includeDocumentation: true
    )

    /// Configuration with signature and documentation.
    public static let signatureAndDocs = SymbolContextConfiguration(
        includeSignature: true,
        includeDocumentation: true
    )

    /// Whether any context extraction is configured.
    public var wantsContext: Bool {
        linesBefore > 0 || linesAfter > 0 || includeScope || includeSignature || includeBody || includeDocumentation
    }

    /// Whether line context is requested.
    public var wantsLines: Bool {
        linesBefore > 0 || linesAfter > 0
    }
}

// MARK: - Context Formatting

extension SymbolContext: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []

        if let doc = documentation, doc.hasContent {
            parts.append("Documentation:")
            if let summary = doc.summary {
                parts.append("  \(summary)")
            }
            for param in doc.parameters {
                parts.append("  - Parameter \(param.name): \(param.description)")
            }
            if let returns = doc.returns {
                parts.append("  - Returns: \(returns)")
            }
            if let throwsDoc = doc.throws {
                parts.append("  - Throws: \(throwsDoc)")
            }
        }

        if !linesBefore.isEmpty || !linesAfter.isEmpty {
            parts.append("Source:")
            for line in linesBefore {
                parts.append(line.formatted())
            }
            for line in linesAfter {
                parts.append(line.formatted())
            }
        }

        if let scope = scopeContent {
            parts.append("Scope: \(scope.kind.rawValue)\(scope.name.map { " '\($0)'" } ?? "")")
            parts.append("  Lines \(scope.startLine)-\(scope.endLine)")
        }

        if let sig = completeSignature {
            parts.append("Signature: \(sig)")
        }

        if let body = body {
            let preview = body.prefix(100)
            parts.append("Body: \(preview)\(body.count > 100 ? "..." : "")")
        }

        return parts.isEmpty ? "SymbolContext(empty)" : parts.joined(separator: "\n")
    }
}
