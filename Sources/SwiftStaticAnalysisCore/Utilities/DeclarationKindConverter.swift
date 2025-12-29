//
//  DeclarationKindConverter.swift
//  SwiftStaticAnalysis
//
//  Shared utilities for converting between different declaration kind representations.
//

import Foundation

// MARK: - DeclarationKindConvertible

/// Protocol for types that can be converted to DeclarationKind.
public protocol DeclarationKindConvertible {
    /// Convert to a DeclarationKind.
    func toDeclarationKind() -> DeclarationKind
}

// MARK: - DeclarationKindFilter

/// Shared logic for determining whether a declaration kind should be reported.
public struct DeclarationKindFilter: Sendable {
    // MARK: Lifecycle

    public init(
        detectVariables: Bool = true,
        detectFunctions: Bool = true,
        detectTypes: Bool = true,
        detectParameters: Bool = true,
    ) {
        self.detectVariables = detectVariables
        self.detectFunctions = detectFunctions
        self.detectTypes = detectTypes
        self.detectParameters = detectParameters
    }

    // MARK: Public

    public let detectVariables: Bool
    public let detectFunctions: Bool
    public let detectTypes: Bool
    public let detectParameters: Bool

    /// Check if a declaration kind should be reported based on configuration.
    public func shouldReport(_ kind: DeclarationKind) -> Bool {
        switch kind {
        case .constant,
             .variable:
            detectVariables
        case .deinitializer,
             .function,
             .initializer,
             .method,
             .subscript:
            detectFunctions
        case .associatedtype,
             .class,
             .enum,
             .extension,
             .protocol,
             .struct,
             .typealias:
            detectTypes
        case .parameter:
            detectParameters
        case .enumCase,
             .import,
             .operator:
            true
        }
    }
}
