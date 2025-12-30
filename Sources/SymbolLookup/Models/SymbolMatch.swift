//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftStaticAnalysis open source project
//
// Copyright (c) 2024 the SwiftStaticAnalysis project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import SwiftStaticAnalysisCore

/// A symbol match result from a lookup query.
///
/// Contains the declaration information, location, isolation domain,
/// and metadata about the match source.
public struct SymbolMatch: Sendable, Hashable, Codable {
    /// The symbol's USR if known from IndexStore.
    public let usr: String?

    /// The symbol name.
    public let name: String

    /// Declaration kind.
    public let kind: DeclarationKind

    /// Access level of the declaration.
    public let accessLevel: AccessLevel

    /// File path where the symbol is defined.
    public let file: String

    /// Line number of the definition (1-indexed).
    public let line: Int

    /// Column number of the definition (1-indexed).
    public let column: Int

    /// Whether this is a static member.
    public let isStatic: Bool

    /// Containing type name for members.
    public let containingType: String?

    /// Module name if known.
    public let moduleName: String?

    /// Type annotation or signature if available.
    public let typeSignature: String?

    /// Function/method signature (for callables).
    public let signature: FunctionSignature?

    /// Generic type parameters (if any).
    public let genericParameters: [String]

    /// Source of this match.
    public let source: Source

    /// How this match was obtained.
    public enum Source: String, Sendable, Codable, Hashable {
        /// Resolved via IndexStoreDB.
        case indexStore

        /// Resolved via SwiftSyntax parsing.
        case syntaxTree

        /// Resolved via cached data.
        case cached
    }

    /// Creates a new symbol match.
    public init(
        usr: String? = nil,
        name: String,
        kind: DeclarationKind,
        accessLevel: AccessLevel,
        file: String,
        line: Int,
        column: Int,
        isStatic: Bool = false,
        containingType: String? = nil,
        moduleName: String? = nil,
        typeSignature: String? = nil,
        signature: FunctionSignature? = nil,
        genericParameters: [String] = [],
        source: Source
    ) {
        self.usr = usr
        self.name = name
        self.kind = kind
        self.accessLevel = accessLevel
        self.file = file
        self.line = line
        self.column = column
        self.isStatic = isStatic
        self.containingType = containingType
        self.moduleName = moduleName
        self.typeSignature = typeSignature
        self.signature = signature
        self.genericParameters = genericParameters
        self.source = source
    }
}

// MARK: - Convenience Properties

extension SymbolMatch {
    /// Full qualified name including containing type.
    public var qualifiedName: String {
        if let container = containingType {
            return "\(container).\(name)"
        }
        return name
    }

    /// Location string in "file:line:column" format.
    public var locationString: String {
        "\(file):\(line):\(column)"
    }

    /// Location string in Xcode-compatible format.
    public var xcodeLocationString: String {
        "\(file):\(line):\(column):"
    }

    /// Whether this symbol is a type.
    public var isType: Bool {
        switch kind {
        case .class, .struct, .enum, .protocol, .typealias:
            return true
        default:
            return false
        }
    }

    /// Whether this symbol is a member of a type.
    public var isMember: Bool {
        containingType != nil
    }

    /// Whether this is an instance member.
    public var isInstanceMember: Bool {
        isMember && !isStatic
    }
}

// MARK: - Factory Methods

extension SymbolMatch {
    /// Creates a SymbolMatch from a Declaration.
    ///
    /// - Parameters:
    ///   - declaration: The declaration to convert.
    ///   - usr: Optional USR if known.
    ///   - containingType: Optional containing type name.
    ///   - source: How the match was obtained.
    /// - Returns: A new SymbolMatch.
    public static func from(
        declaration: Declaration,
        usr: String? = nil,
        containingType: String? = nil,
        source: Source
    ) -> SymbolMatch {
        SymbolMatch(
            usr: usr,
            name: declaration.name,
            kind: declaration.kind,
            accessLevel: declaration.accessLevel,
            file: declaration.location.file,
            line: declaration.location.line,
            column: declaration.location.column,
            isStatic: declaration.modifiers.contains(.static),
            containingType: containingType,
            moduleName: nil,
            typeSignature: declaration.typeAnnotation,
            signature: declaration.signature,
            genericParameters: declaration.genericParameters,
            source: source
        )
    }

    /// Selector-style name for functions (e.g., "fetch(id:)").
    public var selectorName: String {
        guard let sig = signature else {
            return name
        }
        return name + sig.selectorString
    }

    /// Full display name with signature (e.g., "fetch(id: String) -> Data").
    public var displayNameWithSignature: String {
        guard let sig = signature else {
            if !genericParameters.isEmpty {
                return "\(name)<\(genericParameters.joined(separator: ", "))>"
            }
            return name
        }
        var result = name
        if !genericParameters.isEmpty {
            result += "<\(genericParameters.joined(separator: ", "))>"
        }
        result += sig.displayString
        return result
    }
}

// MARK: - CustomStringConvertible

extension SymbolMatch: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []

        // Build name with optional signature
        var symbolName = ""
        if let container = containingType {
            if isStatic {
                symbolName = "static \(container).\(name)"
            } else {
                symbolName = "\(container).\(name)"
            }
        } else {
            symbolName = name
        }

        // Add generic parameters
        if !genericParameters.isEmpty {
            symbolName += "<\(genericParameters.joined(separator: ", "))>"
        }

        // Add signature for functions/methods
        if let sig = signature {
            symbolName += sig.selectorString
        }

        parts.append(symbolName)
        parts.append("(\(kind.rawValue))")
        parts.append("at \(locationString)")

        return parts.joined(separator: " ")
    }
}

// MARK: - Comparable

extension SymbolMatch: Comparable {
    public static func < (lhs: SymbolMatch, rhs: SymbolMatch) -> Bool {
        if lhs.file != rhs.file {
            return lhs.file < rhs.file
        }
        if lhs.line != rhs.line {
            return lhs.line < rhs.line
        }
        return lhs.column < rhs.column
    }
}
