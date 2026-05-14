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
///
/// All stored state is `let` after init and the underlying `IndexStoreReader`
/// is already `Sendable`, so no `@unchecked` annotation is required.
public final class IndexStoreAnalyzer: Sendable {
    // MARK: Lifecycle

    /// Initialize with an index store reader and files to analyze.
    public init(reader: IndexStoreReader, files: [String]) {
        self.reader = reader
        self.files = Set(files.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    // MARK: Public

    /// Analyze all symbols and return their usage information.
    ///
    /// Before 0.2.0 this method was O(definitions × total_occurrences):
    /// each definition triggered a separate `findOccurrences(ofUSR:)` index
    /// query. We now sweep every analysed file once via
    /// `reader.allOccurrencesByUSR(in:)` and look up locally, dropping the
    /// cost to O(total_occurrences) regardless of how many definitions exist.
    public func analyzeUsage() -> [SymbolUsage] {
        let occurrencesByUSR = reader.allOccurrencesByUSR(in: files)

        var usageMap: [String: SymbolUsage] = [:]
        usageMap.reserveCapacity(occurrencesByUSR.count)

        for (usr, occurrences) in occurrencesByUSR {
            // Find the canonical definition occurrence (definition or
            // declaration role, located inside one of our analysed files).
            guard let definition = occurrences.first(where: { occ in
                occ.roles.isDefinitionLike && files.contains(occ.file)
            }) else {
                continue
            }

            if shouldSkipSymbol(definition.symbol) {
                continue
            }

            usageMap[usr] = makeSymbolUsage(definition: definition, occurrences: occurrences)
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

    /// Build a `SymbolUsage` from a precomputed occurrence list.
    ///
    /// Pure function over `occurrences` - no index round-trip - so callers
    /// that already paid for an N-sweep can use it without re-querying.
    private func makeSymbolUsage(
        definition: IndexedOccurrence,
        occurrences: [IndexedOccurrence]
    ) -> SymbolUsage {
        let symbol = definition.symbol
        let usr = symbol.usr

        var referenceCount = 0
        var definitionFiles = Set<String>()
        var referenceFiles = Set<String>()

        for occ in occurrences {
            if occ.roles.isDefinitionLike {
                definitionFiles.insert(occ.file)
            }

            if occ.roles.indicatesUsage {
                referenceCount += 1
                referenceFiles.insert(occ.file)
            }
        }

        // Check if only self-referenced
        let onlySelfReferenced = referenceCount > 0 && referenceFiles.isSubset(of: definitionFiles)

        // Check if it's a test symbol
        let isTestSymbol = matchesTestFilePath(definition.file) && symbol.name.hasPrefix("test")

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
