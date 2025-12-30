//
//  UnusedCodeDetector+IndexStore.swift
//  SwiftStaticAnalysis
//
//  IndexStore-based unused code detection.
//

import Foundation
import IndexStoreDB
import SwiftStaticAnalysisCore

// MARK: - IndexStore Detection

extension UnusedCodeDetector {
    /// Detect unused code using IndexStoreDB (accurate but requires project build).
    func detectUnusedWithIndexStore(in files: [String]) async throws -> [UnusedCode] {
        // Find project root
        guard let projectRoot = findProjectRoot(for: files) else {
            // Fall back to reachability-only analysis
            return try await detectUnusedWithReachability(in: files)
        }

        // Create fallback manager with configuration
        let fallbackConfig = FallbackConfiguration(
            autoBuild: configuration.autoBuild,
            checkFreshness: true,
            warnOnStale: configuration.warnOnStaleIndex,
            hybridMode: configuration.hybridMode,
        )
        let fallbackManager = IndexStoreFallbackManager(configuration: fallbackConfig)

        // Determine which mode to use
        let modeResult = await fallbackManager.determineAnalysisMode(
            projectRoot: projectRoot,
            sourceFiles: files,
            preferredMode: configuration.mode,
        )

        switch modeResult {
        case .indexStore(let db, _):
            // Use index-based dependency graph
            return detectWithIndexGraph(db: db, files: files)

        case .hybrid(let db, _):
            // Combine index and syntax analysis
            return try await detectWithHybridMode(db: db, files: files)

        case .reachability(let reason):
            // Log the reason and fall back
            if configuration.warnOnStaleIndex {
                print("Note: \(reason.description)")
                print("Falling back to reachability-based analysis.")
            }
            return try await detectUnusedWithReachability(in: files)
        }
    }

    /// Detect unused code using the index-based dependency graph.
    func detectWithIndexGraph(db: IndexStoreDB, files: [String]) -> [UnusedCode] {
        // Configure the graph
        let graphConfig = IndexGraphConfiguration(
            treatTestsAsRoot: configuration.treatTestsAsRoot,
            treatProtocolRequirementsAsRoot: true,
            includeCrossModuleEdges: true,
            trackProtocolWitnesses: true
        )

        // Build the graph
        let graph = IndexBasedDependencyGraph(analysisFiles: files, configuration: graphConfig)
        graph.build(from: db)

        // Get unreachable nodes
        let unreachable = graph.computeUnreachable()

        // Convert to UnusedCode
        return unreachable.compactMap { node -> UnusedCode? in
            // Skip external symbols
            guard !node.isExternal else { return nil }

            // Apply configuration filters
            if !shouldReportIndexNode(node) {
                return nil
            }

            guard let file = node.definitionFile,
                let line = node.definitionLine
            else {
                return nil
            }

            let location = SourceLocation(file: file, line: line, column: 1, offset: 0)
            let declaration = Declaration(
                name: node.name,
                kind: convertIndexKind(node.kind),
                accessLevel: .internal,  // Not available from index
                modifiers: [],
                location: location,
                range: SourceRange(start: location, end: location),
                scope: .global,
            )

            return UnusedCode(
                declaration: declaration,
                reason: .neverReferenced,
                confidence: .high,  // High confidence from index analysis
                suggestion: "Unreachable symbol '\(node.name)' - consider removing",
            )
        }
        .filter { $0.confidence >= configuration.minimumConfidence }
        .sorted { $0.confidence > $1.confidence }
    }

    /// Detect unused code using hybrid mode (index + syntax).
    func detectWithHybridMode(db: IndexStoreDB, files: [String]) async throws -> [UnusedCode] {
        // Get results from both methods
        let indexResults = detectWithIndexGraph(db: db, files: files)
        let syntaxResults = try await detectUnusedWithReachability(in: files)

        // Merge results, preferring index results for higher confidence
        var resultsByName: [String: UnusedCode] = [:]

        // Add index results first (higher confidence)
        for result in indexResults {
            resultsByName[result.declaration.name] = result
        }

        // Add syntax results only if not already present
        for result in syntaxResults where resultsByName[result.declaration.name] == nil {
            resultsByName[result.declaration.name] = result
        }

        return Array(resultsByName.values)
            .filter { $0.confidence >= configuration.minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Check if an index node should be reported.
    func shouldReportIndexNode(_ node: IndexSymbolNode) -> Bool {
        let filter = DeclarationKindFilter(
            detectVariables: configuration.detectVariables,
            detectFunctions: configuration.detectFunctions,
            detectTypes: configuration.detectTypes,
            detectParameters: configuration.detectParameters,
        )
        return filter.shouldReport(node.kind.toDeclarationKind())
    }

    /// Convert index kind to declaration kind.
    func convertIndexKind(_ kind: IndexedSymbolKind) -> DeclarationKind {
        kind.toDeclarationKind()
    }
}

// MARK: - Project Discovery

extension UnusedCodeDetector {
    /// Find the project root for the given files.
    func findProjectRoot(for files: [String]) -> String? {
        guard let firstFile = files.first else { return nil }

        var current = URL(fileURLWithPath: firstFile).deletingLastPathComponent()
        let maxDepth = 10

        for _ in 0..<maxDepth {
            // Check for Package.swift (Swift package)
            let packageSwift = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return current.path
            }

            // Check for .xcodeproj or .xcworkspace
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
            {
                return current.path
            }

            current = current.deletingLastPathComponent()
        }

        return nil
    }

    /// Find the index store path for the given files.
    func findIndexStorePath(for files: [String]) -> String? {
        guard let firstFile = files.first else { return nil }

        // Walk up from the first file to find project root
        var current = URL(fileURLWithPath: firstFile).deletingLastPathComponent()
        let maxDepth = 10

        for _ in 0..<maxDepth {
            // Check for Package.swift (Swift package)
            let packageSwift = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return IndexStorePathFinder.findIndexStorePath(in: current.path)
            }

            // Check for .xcodeproj
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                contents.contains(where: { $0.hasSuffix(".xcodeproj") })
            {
                return IndexStorePathFinder.findIndexStorePath(in: current.path)
            }

            current = current.deletingLastPathComponent()
        }

        return nil
    }
}
