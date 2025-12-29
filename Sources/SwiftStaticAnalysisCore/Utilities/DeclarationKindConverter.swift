//
//  DeclarationKindConverter.swift
//  SwiftStaticAnalysis
//
//  Shared utilities for converting between different declaration kind representations.
//

import Foundation

// MARK: - Declaration Kind Conversion Protocol

/// Protocol for types that can be converted to DeclarationKind.
public protocol DeclarationKindConvertible {
    /// Convert to a DeclarationKind.
    func toDeclarationKind() -> DeclarationKind
}

// MARK: - Configuration Filtering

/// Shared logic for determining whether a declaration kind should be reported.
public struct DeclarationKindFilter: Sendable {
    public let detectVariables: Bool
    public let detectFunctions: Bool
    public let detectTypes: Bool
    public let detectParameters: Bool

    public init(
        detectVariables: Bool = true,
        detectFunctions: Bool = true,
        detectTypes: Bool = true,
        detectParameters: Bool = true
    ) {
        self.detectVariables = detectVariables
        self.detectFunctions = detectFunctions
        self.detectTypes = detectTypes
        self.detectParameters = detectParameters
    }

    /// Check if a declaration kind should be reported based on configuration.
    public func shouldReport(_ kind: DeclarationKind) -> Bool {
        switch kind {
        case .variable, .constant:
            return detectVariables
        case .function, .method, .initializer, .deinitializer, .subscript:
            return detectFunctions
        case .class, .struct, .enum, .protocol, .extension, .typealias, .associatedtype:
            return detectTypes
        case .parameter:
            return detectParameters
        case .import, .operator, .enumCase:
            return true
        }
    }
}
