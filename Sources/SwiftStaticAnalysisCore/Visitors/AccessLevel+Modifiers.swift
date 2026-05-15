//  AccessLevel+Modifiers.swift
//  SwiftStaticAnalysis
//  MIT License

import SwiftSyntax

extension AccessLevel {
    /// Resolve the effective access level from a SwiftSyntax modifier list.
    ///
    /// Returns the first explicit access-level keyword in the list, or
    /// `.internal` (Swift's default) when none is present.
    public static func from(_ modifiers: DeclModifierListSyntax) -> AccessLevel {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.private): return .private
            case .keyword(.fileprivate): return .fileprivate
            case .keyword(.internal): return .internal
            case .keyword(.package): return .package
            case .keyword(.public): return .public
            case .keyword(.open): return .open
            default: continue
            }
        }
        return .internal
    }
}
