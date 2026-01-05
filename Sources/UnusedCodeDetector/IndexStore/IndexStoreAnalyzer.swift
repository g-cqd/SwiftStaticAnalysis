//  IndexStoreAnalyzer.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore

// MARK: - SymbolUsage

/// Tracks usage information for a symbol.
public struct SymbolUsage: Sendable {
    // MARK: Lifecycle

    public init(
        usr: String,
        name: String,
        kind: IndexedSymbolKind,
        definitionLocation: SourceLocation?,
        referenceCount: Int,
        onlySelfReferenced: Bool,
        isTestSymbol: Bool,
    ) {
        self.usr = usr
        self.name = name
        self.kind = kind
        self.definitionLocation = definitionLocation
        self.referenceCount = referenceCount
        self.onlySelfReferenced = onlySelfReferenced
        self.isTestSymbol = isTestSymbol
    }

    // MARK: Public

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

    /// Whether this symbol is unused.
    public var isUnused: Bool {
        referenceCount == 0
    }
}

// MARK: - IndexStoreAnalyzer

/// Analyzes symbol usage using the index store.
public final class IndexStoreAnalyzer: @unchecked Sendable {
    // MARK: Lifecycle

    /// Initialize with an index store reader and files to analyze.
    public init(reader: IndexStoreReader, files: [String]) {
        self.reader = reader
        self.files = Set(files.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    // MARK: Public

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
        analyzeUsage().filter(\.isUnused)
    }

    // MARK: Private

    /// The index store reader.
    private let reader: IndexStoreReader

    /// Files to analyze.
    private let files: Set<String>

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

            if occ.roles.contains(.reference) || occ.roles.contains(.call) || occ.roles.contains(.read) {
                referenceCount += 1
                referenceFiles.insert(occ.file)
            }
        }

        // Check if only self-referenced
        let onlySelfReferenced = referenceCount > 0 && referenceFiles.isSubset(of: definitionFiles)

        // Check if it's a test symbol
        let isTestSymbol =
            symbol.name.hasPrefix("test") || definition.file.contains("Tests") || definition.file.contains("Test")

        let definitionLocation = SourceLocation(
            file: definition.file,
            line: definition.line,
            column: definition.column,
            offset: 0,
        )

        return SymbolUsage(
            usr: usr,
            name: symbol.name,
            kind: symbol.kind,
            definitionLocation: definitionLocation,
            referenceCount: referenceCount,
            onlySelfReferenced: onlySelfReferenced,
            isTestSymbol: isTestSymbol,
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

// MARK: - IndexStoreBasedDetector

/// Unused code detector that uses the index store for accurate detection.
public struct IndexStoreBasedDetector: Sendable {
    // MARK: Lifecycle

    public init(configuration: UnusedCodeConfiguration) {
        self.configuration = configuration
    }

    // MARK: Public

    /// Configuration.
    public let configuration: UnusedCodeConfiguration

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
                accessLevel: .internal,  // We don't have this info from index store
                modifiers: [],
                location: location,
                range: SourceRange(start: location, end: location),
                scope: .global,
            )

            let reason: UnusedReason = usage.onlySelfReferenced ? .onlySelfReferenced : .neverReferenced
            let confidence: Confidence = .high  // Index store is accurate

            return UnusedCode(
                declaration: declaration,
                reason: reason,
                confidence: confidence,
                suggestion: generateSuggestion(for: usage),
            )
        }
    }

    // MARK: Private

    /// Check if a symbol should be reported based on configuration.
    private func shouldReport(_ usage: SymbolUsage) -> Bool {
        let filter = DeclarationKindFilter(
            detectVariables: configuration.detectVariables,
            detectFunctions: configuration.detectFunctions,
            detectTypes: configuration.detectTypes,
            detectParameters: configuration.detectParameters,
        )
        return filter.shouldReport(usage.kind.toDeclarationKind())
    }

    /// Convert index kind to declaration kind.
    private func convertKind(_ kind: IndexedSymbolKind) -> DeclarationKind {
        kind.toDeclarationKind()
    }

    /// Generate a suggestion for the unused symbol.
    private func generateSuggestion(for usage: SymbolUsage) -> String {
        if usage.onlySelfReferenced {
            return "'\(usage.name)' is only referenced within its own definition"
        }

        let kindName =
            switch usage.kind {
            case .class: "class"
            case .struct: "struct"
            case .enum: "enum"
            case .protocol: "protocol"
            case .function,
                .method:
                "function"
            case .property,
                .variable:
                "variable"
            case .parameter: "parameter"
            default: "symbol"
            }

        return "Consider removing unused \(kindName) '\(usage.name)'"
    }
}
