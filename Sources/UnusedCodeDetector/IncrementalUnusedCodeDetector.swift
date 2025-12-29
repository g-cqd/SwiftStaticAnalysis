//
//  IncrementalUnusedCodeDetector.swift
//  SwiftStaticAnalysis
//
//  Incremental unused code detector with caching support.
//

import Foundation
import SwiftStaticAnalysisCore

// MARK: - Incremental Unused Code Result

/// Result of incremental unused code detection.
public struct IncrementalUnusedCodeResult: Sendable {
    /// Detected unused code.
    public let unusedCode: [UnusedCode]

    /// Files that were analyzed (not cached).
    public let analyzedFiles: [String]

    /// Files loaded from cache.
    public let cachedFiles: [String]

    /// Time saved by using cache (estimated milliseconds).
    public let timeSavedMs: Double

    /// Cache hit rate percentage.
    public var cacheHitRate: Double {
        let total = analyzedFiles.count + cachedFiles.count
        return total > 0 ? Double(cachedFiles.count) / Double(total) * 100 : 0
    }
}

// MARK: - Incremental Unused Code Detector

/// Actor-based incremental unused code detector with caching.
public actor IncrementalUnusedCodeDetector {

    /// Configuration for detection.
    public let configuration: UnusedCodeConfiguration

    /// Concurrency configuration.
    public let concurrency: ConcurrencyConfiguration

    /// Incremental analyzer.
    private let incrementalAnalyzer: IncrementalAnalyzer

    /// Whether initialized.
    private var isInitialized: Bool = false

    // MARK: - Initialization

    public init(
        configuration: UnusedCodeConfiguration = .incremental(),
        concurrency: ConcurrencyConfiguration = .default
    ) {
        self.configuration = configuration
        self.concurrency = concurrency

        let incrementalConfig = IncrementalConfiguration(
            cacheDirectory: configuration.cacheDirectory,
            trackDependencies: true,
            concurrency: concurrency
        )
        self.incrementalAnalyzer = IncrementalAnalyzer(configuration: incrementalConfig)
    }

    /// Initialize by loading caches from disk.
    public func initialize() async throws {
        guard !isInitialized else { return }
        try await incrementalAnalyzer.initialize()
        isInitialized = true
    }

    /// Save caches to disk.
    public func save() async throws {
        try await incrementalAnalyzer.save()
    }

    /// Clear all caches.
    public func clearCache() async {
        await incrementalAnalyzer.clearCache()
    }

    // MARK: - Detection

    /// Detect unused code incrementally.
    ///
    /// - Parameter files: Files to analyze.
    /// - Returns: Incremental detection result.
    public func detectUnused(in files: [String]) async throws -> IncrementalUnusedCodeResult {
        try await initialize()

        // Perform incremental analysis
        let analysisResult = try await incrementalAnalyzer.analyze(files)

        // Run unused code detection on the combined result
        let unusedCode = detectUnusedCode(in: analysisResult.result)

        return IncrementalUnusedCodeResult(
            unusedCode: unusedCode,
            analyzedFiles: analysisResult.analyzedFiles,
            cachedFiles: analysisResult.cachedFiles,
            timeSavedMs: analysisResult.timeSavedMs
        )
    }

    // MARK: - Private Detection

    /// Detect unused code from analysis result.
    private func detectUnusedCode(in result: AnalysisResult) -> [UnusedCode] {
        var unused: [UnusedCode] = []

        // Build reference counts
        var referenceCounts: [String: Int] = [:]
        for ref in result.references.references {
            referenceCounts[ref.identifier, default: 0] += 1
        }

        // Check each declaration
        for declaration in result.declarations.declarations {
            // Skip if not a type we're detecting
            guard shouldCheck(declaration) else { continue }

            // Skip if filtered out
            guard passesFilters(declaration) else { continue }

            // Check reference count
            let count = referenceCounts[declaration.name] ?? 0

            if count == 0 {
                // No references at all
                let confidence = declaration.unusedConfidence
                if confidence >= configuration.minimumConfidence {
                    unused.append(UnusedCode(
                        declaration: declaration,
                        reason: .neverReferenced,
                        confidence: confidence,
                        suggestion: suggestion(for: declaration)
                    ))
                }
            } else if isSelfReferenceOnly(declaration, referenceCount: count, in: result) {
                // Only referenced by itself
                let confidence = declaration.unusedConfidence
                if confidence >= configuration.minimumConfidence {
                    unused.append(UnusedCode(
                        declaration: declaration,
                        reason: .onlySelfReferenced,
                        confidence: confidence,
                        suggestion: suggestion(for: declaration)
                    ))
                }
            }
        }

        // Check imports if enabled
        if configuration.detectImports {
            unused.append(contentsOf: detectUnusedImports(in: result))
        }

        return unused.sorted { $0.confidence > $1.confidence }
    }

    /// Check if a declaration should be checked based on configuration.
    private func shouldCheck(_ declaration: Declaration) -> Bool {
        switch declaration.kind {
        case .variable, .constant:
            return configuration.detectVariables
        case .function, .method:
            return configuration.detectFunctions
        case .class, .struct, .enum, .protocol:
            return configuration.detectTypes
        case .import:
            return configuration.detectImports
        case .parameter:
            return configuration.detectParameters
        default:
            return false
        }
    }

    /// Check if declaration passes configured filters.
    private func passesFilters(_ declaration: Declaration) -> Bool {
        // Check public API filter
        if configuration.ignorePublicAPI &&
           (declaration.accessLevel == .public || declaration.accessLevel == .open) {
            return false
        }

        // Check ignored patterns
        for pattern in configuration.ignoredPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: declaration.name, range: NSRange(declaration.name.startIndex..., in: declaration.name)) != nil {
                return false
            }
        }

        // SwiftUI filters
        if configuration.ignoreSwiftUIPropertyWrappers && declaration.hasSwiftUIPropertyWrapper {
            return false
        }

        if configuration.ignoreViewBody && declaration.name == "body" && declaration.kind == .variable {
            return false
        }

        if configuration.ignorePreviewProviders && declaration.isSwiftUIPreview {
            return false
        }

        // Check @objc as root
        if configuration.treatObjcAsRoot && declaration.attributes.contains("objc") {
            return false
        }

        return true
    }

    /// Check if a declaration is only referenced by itself.
    private func isSelfReferenceOnly(
        _ declaration: Declaration,
        referenceCount: Int,
        in result: AnalysisResult
    ) -> Bool {
        // For now, simplified check - if there's only one reference
        // and it's in the same file, it might be self-referencing
        if referenceCount == 1 {
            let refs = result.references.byIdentifier[declaration.name] ?? []
            if let ref = refs.first, ref.location.file == declaration.location.file {
                // Could be self-reference (e.g., recursive function)
                return true
            }
        }
        return false
    }

    /// Generate suggestion for unused declaration.
    private func suggestion(for declaration: Declaration) -> String {
        switch declaration.kind {
        case .function, .method:
            return "Consider removing this unused function"
        case .variable, .constant:
            return "Consider removing this unused variable"
        case .class, .struct:
            return "Consider removing this unused type"
        case .protocol:
            return "Consider removing this unused protocol"
        case .import:
            return "Consider removing this unused import"
        default:
            return "Consider removing this unused declaration"
        }
    }

    /// Detect unused imports.
    private func detectUnusedImports(in result: AnalysisResult) -> [UnusedCode] {
        var unused: [UnusedCode] = []

        let imports = result.declarations.declarations.filter { $0.kind == .import }
        let referencedIdentifiers = Set(result.references.references.map(\.identifier))

        for importDecl in imports {
            // Simple heuristic: if the import name isn't referenced anywhere
            // (This is a rough check - real import checking requires type resolution)
            if !referencedIdentifiers.contains(importDecl.name) {
                unused.append(UnusedCode(
                    declaration: importDecl,
                    reason: .importNotUsed,
                    confidence: .low, // Low confidence without full type resolution
                    suggestion: "Consider removing unused import '\(importDecl.name)'"
                ))
            }
        }

        return unused
    }

    // MARK: - Statistics

    /// Get cache statistics.
    public func cacheStatistics() async -> AnalysisCache.Statistics {
        await incrementalAnalyzer.cacheStatistics()
    }

    /// Get dependency statistics.
    public func dependencyStatistics() async -> DependencyTracker.Statistics {
        await incrementalAnalyzer.dependencyStatistics()
    }
}
