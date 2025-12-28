//
//  IndexStoreAnalyzer.swift
//  SwiftStaticAnalysis
//
//  Analyzes symbol usage using IndexStoreDB for accurate unused code detection.
//

import Foundation
import SwiftStaticAnalysisCore

// MARK: - Symbol Usage

/// Tracks usage information for a symbol.
public struct SymbolUsage: Sendable {
    /// The symbol's USR.
    public let usr: String

    /// The symbol name.
    public let name: String

    /// The kind of symbol.
    public let kind: IndexedSymbolKind

    /// Location of the definition.
    public let definitionLocation: SourceLocation?

    /// Number of references (excluding definition).
    public let referenceCount: Int

    /// Whether the symbol is only referenced from its own definition scope.
    public let onlySelfReferenced: Bool

    /// Whether this appears to be a test symbol.
    public let isTestSymbol: Bool

    public init(
        usr: String,
        name: String,
        kind: IndexedSymbolKind,
        definitionLocation: SourceLocation?,
        referenceCount: Int,
        onlySelfReferenced: Bool,
        isTestSymbol: Bool
    ) {
        self.usr = usr
        self.name = name
        self.kind = kind
        self.definitionLocation = definitionLocation
        self.referenceCount = referenceCount
        self.onlySelfReferenced = onlySelfReferenced
        self.isTestSymbol = isTestSymbol
    }

    /// Whether this symbol is unused.
    public var isUnused: Bool {
        referenceCount == 0
    }
}

// MARK: - Index Store Analyzer

/// Analyzes symbol usage using the index store.
public final class IndexStoreAnalyzer: @unchecked Sendable {
    /// The index store reader.
    private let reader: IndexStoreReader

    /// Files to analyze.
    private let files: Set<String>

    /// Initialize with an index store reader and files to analyze.
    public init(reader: IndexStoreReader, files: [String]) {
        self.reader = reader
        self.files = Set(files.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    /// Analyze all symbols and return their usage information.
    public func analyzeUsage() -> [SymbolUsage] {
        var usageMap: [String: SymbolUsage] = [:]

        // Get all definitions from the index store
        let allDefs = reader.allDefinitions()

        // Filter to only files we care about
        for def in allDefs {
            // Check if this definition is in one of our files
            guard files.contains(def.file) else {
                continue
            }

            guard def.roles.contains(.definition) || def.roles.contains(.declaration) else {
                continue
            }

            // Skip system symbols and certain kinds
            if shouldSkipSymbol(def.symbol) {
                continue
            }

            let usr = def.symbol.usr

            // If we haven't seen this symbol yet, analyze it
            if usageMap[usr] == nil {
                let usage = analyzeSymbol(def)
                usageMap[usr] = usage
            }
        }

        return Array(usageMap.values)
    }

    /// Analyze unused symbols only.
    public func findUnusedSymbols() -> [SymbolUsage] {
        analyzeUsage().filter { $0.isUnused }
    }

    /// Analyze a specific symbol's usage.
    private func analyzeSymbol(_ definition: IndexedOccurrence) -> SymbolUsage {
        let symbol = definition.symbol
        let usr = symbol.usr

        // Get all occurrences
        let occurrences = reader.findOccurrences(ofUSR: usr)

        // Count references (exclude definitions)
        var referenceCount = 0
        var definitionFiles = Set<String>()
        var referenceFiles = Set<String>()

        for occ in occurrences {
            if occ.roles.contains(.definition) || occ.roles.contains(.declaration) {
                definitionFiles.insert(occ.file)
            }

            if occ.roles.contains(.reference) ||
               occ.roles.contains(.call) ||
               occ.roles.contains(.read) {
                referenceCount += 1
                referenceFiles.insert(occ.file)
            }
        }

        // Check if only self-referenced
        let onlySelfReferenced = referenceCount > 0 &&
            referenceFiles.isSubset(of: definitionFiles)

        // Check if it's a test symbol
        let isTestSymbol = symbol.name.hasPrefix("test") ||
            definition.file.contains("Tests") ||
            definition.file.contains("Test")

        let definitionLocation = SourceLocation(
            file: definition.file,
            line: definition.line,
            column: definition.column,
            offset: 0
        )

        return SymbolUsage(
            usr: usr,
            name: symbol.name,
            kind: symbol.kind,
            definitionLocation: definitionLocation,
            referenceCount: referenceCount,
            onlySelfReferenced: onlySelfReferenced,
            isTestSymbol: isTestSymbol
        )
    }

    /// Check if a symbol should be skipped from analysis.
    private func shouldSkipSymbol(_ symbol: IndexedSymbol) -> Bool {
        // Skip system symbols
        if symbol.isSystem {
            return true
        }

        // Skip certain generated symbols
        let name = symbol.name
        if name.hasPrefix("$") || name.hasPrefix("_$") {
            return true
        }

        // Skip init/deinit (these are often implicitly referenced)
        if name == "init" || name == "deinit" {
            return true
        }

        // Skip CodingKeys (used by Codable)
        if name == "CodingKeys" {
            return true
        }

        return false
    }
}

// MARK: - Index Store Based Detector

/// Unused code detector that uses the index store for accurate detection.
public struct IndexStoreBasedDetector: Sendable {
    /// Configuration.
    public let configuration: UnusedCodeConfiguration

    public init(configuration: UnusedCodeConfiguration) {
        self.configuration = configuration
    }

    /// Detect unused code using the index store.
    public func detect(in files: [String], indexStorePath: String) throws -> [UnusedCode] {
        // Create the reader
        let reader = try IndexStoreReader(indexStorePath: indexStorePath)

        // Poll for any recent changes
        reader.pollForChanges()

        // Create analyzer
        let analyzer = IndexStoreAnalyzer(reader: reader, files: files)

        // Get unused symbols
        let unusedSymbols = analyzer.findUnusedSymbols()

        // Convert to UnusedCode
        return unusedSymbols.compactMap { usage -> UnusedCode? in
            // Skip test symbols
            if usage.isTestSymbol {
                return nil
            }

            // Apply configuration filters
            if !shouldReport(usage) {
                return nil
            }

            guard let location = usage.definitionLocation else {
                return nil
            }

            let declaration = Declaration(
                name: usage.name,
                kind: convertKind(usage.kind),
                accessLevel: .internal, // We don't have this info from index store
                modifiers: [],
                location: location,
                range: SourceRange(start: location, end: location),
                scope: .global
            )

            let reason: UnusedReason = usage.onlySelfReferenced ? .onlySelfReferenced : .neverReferenced
            let confidence: Confidence = .high // Index store is accurate

            return UnusedCode(
                declaration: declaration,
                reason: reason,
                confidence: confidence,
                suggestion: generateSuggestion(for: usage)
            )
        }
    }

    /// Check if a symbol should be reported based on configuration.
    private func shouldReport(_ usage: SymbolUsage) -> Bool {
        switch usage.kind {
        case .variable, .property:
            return configuration.detectVariables
        case .function, .method:
            return configuration.detectFunctions
        case .class, .struct, .enum, .protocol:
            return configuration.detectTypes
        case .parameter:
            return configuration.detectParameters
        default:
            return true
        }
    }

    /// Convert index kind to declaration kind.
    private func convertKind(_ kind: IndexedSymbolKind) -> DeclarationKind {
        switch kind {
        case .class: return .class
        case .struct: return .struct
        case .enum: return .enum
        case .protocol: return .protocol
        case .extension: return .extension
        case .function, .method: return .function
        case .property: return .variable
        case .variable: return .variable
        case .parameter: return .parameter
        case .typealias: return .typealias
        case .module: return .import
        case .unknown: return .variable
        }
    }

    /// Generate a suggestion for the unused symbol.
    private func generateSuggestion(for usage: SymbolUsage) -> String {
        if usage.onlySelfReferenced {
            return "'\(usage.name)' is only referenced within its own definition"
        }

        let kindName: String
        switch usage.kind {
        case .class: kindName = "class"
        case .struct: kindName = "struct"
        case .enum: kindName = "enum"
        case .protocol: kindName = "protocol"
        case .function, .method: kindName = "function"
        case .property, .variable: kindName = "variable"
        case .parameter: kindName = "parameter"
        default: kindName = "symbol"
        }

        return "Consider removing unused \(kindName) '\(usage.name)'"
    }
}
