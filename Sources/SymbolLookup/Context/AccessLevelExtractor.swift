//  AccessLevelExtractor.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftParser
import SwiftStaticAnalysisCore
import SwiftSyntax

/// Extracts access levels from Swift source code at specific locations.
///
/// This utility parses Swift source files and extracts access level information
/// from declarations at specified line and column positions. It's primarily used
/// to enrich IndexStore results with accurate access level information, since
/// IndexStore doesn't expose access levels directly.
///
/// ## Thread Safety
///
/// This type is `Sendable` and can be used from any thread. Each extraction
/// reads the file independently.
///
/// ## Performance
///
/// For batch operations on the same file, use `extractAccessLevels(for:)` which
/// parses the file once and extracts multiple access levels.
public struct AccessLevelExtractor: Sendable {
    /// Creates a new access level extractor.
    public init() {}

    /// Extracts the access level for a symbol at a specific location.
    ///
    /// - Parameters:
    ///   - file: Path to the Swift source file.
    ///   - line: Line number (1-indexed).
    ///   - column: Column number (1-indexed).
    /// - Returns: The access level if found, or `.internal` as the default.
    public func extractAccessLevel(
        file: String,
        line: Int,
        column: Int
    ) -> AccessLevel {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else {
            return .internal
        }

        let syntaxTree = Parser.parse(source: content)
        let finder = DeclarationNodeFinder(targetLine: line, targetColumn: column)
        finder.walk(syntaxTree)

        guard let declaration = finder.foundDeclaration else {
            return .internal
        }

        return extractAccessLevelFromNode(declaration)
    }

    /// Extracts access levels for multiple symbols, batched by file.
    ///
    /// This method is more efficient than calling `extractAccessLevel` multiple
    /// times for symbols in the same file, as it parses each file only once.
    ///
    /// - Parameter locations: Array of (file, line, column) tuples.
    /// - Returns: Array of access levels in the same order as the input.
    public func extractAccessLevels(
        for locations: [(file: String, line: Int, column: Int)]
    ) -> [AccessLevel] {
        guard !locations.isEmpty else { return [] }

        var resultsByIndex: [Int: AccessLevel] = [:]

        // Group locations by file to minimize reparsing
        var byFile: [String: [(index: Int, line: Int, column: Int)]] = [:]
        for (index, loc) in locations.enumerated() {
            byFile[loc.file, default: []].append((index, loc.line, loc.column))
        }

        // Process each file
        for (file, fileLocations) in byFile {
            guard let content = try? String(contentsOfFile: file, encoding: .utf8) else {
                // Default to internal for files we can't read
                for loc in fileLocations {
                    resultsByIndex[loc.index] = .internal
                }
                continue
            }

            let syntaxTree = Parser.parse(source: content)

            for loc in fileLocations {
                let finder = DeclarationNodeFinder(targetLine: loc.line, targetColumn: loc.column)
                finder.walk(syntaxTree)

                if let declaration = finder.foundDeclaration {
                    resultsByIndex[loc.index] = extractAccessLevelFromNode(declaration)
                } else {
                    resultsByIndex[loc.index] = .internal
                }
            }
        }

        // Return results in original order
        return (0..<locations.count).map { resultsByIndex[$0] ?? .internal }
    }

    /// Enriches a SymbolMatch with the correct access level from source.
    ///
    /// - Parameter match: The symbol match to enrich.
    /// - Returns: A new SymbolMatch with the correct access level.
    public func enrichWithAccessLevel(_ match: SymbolMatch) -> SymbolMatch {
        let accessLevel = extractAccessLevel(
            file: match.file,
            line: match.line,
            column: match.column
        )

        return SymbolMatch(
            usr: match.usr,
            name: match.name,
            kind: match.kind,
            accessLevel: accessLevel,
            file: match.file,
            line: match.line,
            column: match.column,
            isStatic: match.isStatic,
            containingType: match.containingType,
            moduleName: match.moduleName,
            typeSignature: match.typeSignature,
            signature: match.signature,
            genericParameters: match.genericParameters,
            source: match.source
        )
    }

    /// Enriches multiple SymbolMatches with correct access levels.
    ///
    /// This method is more efficient than calling `enrichWithAccessLevel` multiple
    /// times, as it batches file reads.
    ///
    /// - Parameter matches: The symbol matches to enrich.
    /// - Returns: New SymbolMatches with correct access levels.
    public func enrichWithAccessLevels(_ matches: [SymbolMatch]) -> [SymbolMatch] {
        guard !matches.isEmpty else { return [] }

        let locations = matches.map { (file: $0.file, line: $0.line, column: $0.column) }
        let accessLevels = extractAccessLevels(for: locations)

        return zip(matches, accessLevels).map { match, accessLevel in
            SymbolMatch(
                usr: match.usr,
                name: match.name,
                kind: match.kind,
                accessLevel: accessLevel,
                file: match.file,
                line: match.line,
                column: match.column,
                isStatic: match.isStatic,
                containingType: match.containingType,
                moduleName: match.moduleName,
                typeSignature: match.typeSignature,
                signature: match.signature,
                genericParameters: match.genericParameters,
                source: match.source
            )
        }
    }

    // MARK: - Private

    /// Extracts the access level from a syntax node.
    private func extractAccessLevelFromNode(_ node: Syntax) -> AccessLevel {
        // Try to get modifiers from different declaration types
        let modifiers: DeclModifierListSyntax? =
            if let funcDecl = node.as(FunctionDeclSyntax.self) {
                funcDecl.modifiers
            } else if let varDecl = node.as(VariableDeclSyntax.self) {
                varDecl.modifiers
            } else if let classDecl = node.as(ClassDeclSyntax.self) {
                classDecl.modifiers
            } else if let structDecl = node.as(StructDeclSyntax.self) {
                structDecl.modifiers
            } else if let enumDecl = node.as(EnumDeclSyntax.self) {
                enumDecl.modifiers
            } else if let protocolDecl = node.as(ProtocolDeclSyntax.self) {
                protocolDecl.modifiers
            } else if let extensionDecl = node.as(ExtensionDeclSyntax.self) {
                extensionDecl.modifiers
            } else if let actorDecl = node.as(ActorDeclSyntax.self) {
                actorDecl.modifiers
            } else if let initDecl = node.as(InitializerDeclSyntax.self) {
                initDecl.modifiers
            } else if let deinitDecl = node.as(DeinitializerDeclSyntax.self) {
                deinitDecl.modifiers
            } else if let subscriptDecl = node.as(SubscriptDeclSyntax.self) {
                subscriptDecl.modifiers
            } else if let typealiasDecl = node.as(TypeAliasDeclSyntax.self) {
                typealiasDecl.modifiers
            } else if let associatedTypeDecl = node.as(AssociatedTypeDeclSyntax.self) {
                associatedTypeDecl.modifiers
            } else {
                nil
            }

        guard let modifiers else {
            return .internal
        }

        return extractAccessLevel(from: modifiers)
    }

    /// Extracts access level from modifier list.
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
}
