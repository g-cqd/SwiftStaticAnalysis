//  IncrementalUnusedCodeDetector.swift
//  SwiftStaticAnalysis
//  MIT License

import RegexBuilder
import SwiftStaticAnalysisCore

// MARK: - IncrementalUnusedCodeResult

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

// MARK: - IncrementalUnusedCodeDetector

/// Actor-based incremental unused code detector with caching.
public actor IncrementalUnusedCodeDetector {
    // MARK: Lifecycle

    // MARK: - Initialization

    public init(
        configuration: UnusedCodeConfiguration = .incremental(),
        concurrency: ConcurrencyConfiguration = .default,
    ) {
        self.configuration = configuration
        self.concurrency = concurrency
        // Pre-compile ignore patterns for efficient matching
        compiledIgnorePatterns = CompiledPatterns(configuration.ignoredPatterns)

        let incrementalConfig = IncrementalConfiguration(
            cacheDirectory: configuration.cacheDirectory,
            trackDependencies: true,
            concurrency: concurrency,
        )
        incrementalAnalyzer = IncrementalAnalyzer(configuration: incrementalConfig)
    }

    // MARK: Public

    /// Configuration for detection.
    public let configuration: UnusedCodeConfiguration

    /// Concurrency configuration.
    public let concurrency: ConcurrencyConfiguration

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
            timeSavedMs: analysisResult.timeSavedMs,
        )
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

    // MARK: Private

    /// Incremental analyzer.
    private let incrementalAnalyzer: IncrementalAnalyzer

    /// Pre-compiled ignore patterns for efficient matching.
    private let compiledIgnorePatterns: CompiledPatterns

    /// Whether initialized.
    private var isInitialized: Bool = false

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
                    unused.append(
                        UnusedCode(
                            declaration: declaration,
                            reason: .neverReferenced,
                            confidence: confidence,
                            suggestion: suggestion(for: declaration),
                        ))
                }
            } else if isSelfReferenceOnly(declaration, referenceCount: count, in: result) {
                // Only referenced by itself
                let confidence = declaration.unusedConfidence
                if confidence >= configuration.minimumConfidence {
                    unused.append(
                        UnusedCode(
                            declaration: declaration,
                            reason: .onlySelfReferenced,
                            confidence: confidence,
                            suggestion: suggestion(for: declaration),
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
        case .constant,
            .variable:
            configuration.detectVariables

        case .function,
            .method:
            configuration.detectFunctions

        case .class,
            .enum,
            .protocol,
            .struct:
            configuration.detectTypes

        case .import:
            configuration.detectImports

        case .parameter:
            configuration.detectParameters

        default:
            false
        }
    }

    /// Check if declaration passes configured filters.
    private func passesFilters(_ declaration: Declaration) -> Bool {
        // Check public API filter
        if configuration.ignorePublicAPI,
            declaration.accessLevel == .public || declaration.accessLevel == .open
        {
            return false
        }

        // Check ignored patterns using pre-compiled patterns
        if compiledIgnorePatterns.anyMatches(declaration.name) {
            return false
        }

        // SwiftUI filters
        if configuration.ignoreSwiftUIPropertyWrappers, declaration.hasSwiftUIPropertyWrapper {
            return false
        }

        if configuration.ignoreViewBody, declaration.name == "body", declaration.kind == .variable {
            return false
        }

        if configuration.ignorePreviewProviders, declaration.isSwiftUIPreview {
            return false
        }

        // Check @objc as root
        if configuration.treatObjcAsRoot, declaration.attributes.contains("objc") {
            return false
        }

        return true
    }

    /// Check if a declaration is only referenced by itself.
    private func isSelfReferenceOnly(
        _ declaration: Declaration,
        referenceCount: Int,
        in result: AnalysisResult,
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
        case .function,
            .method:
            "Consider removing this unused function"

        case .constant,
            .variable:
            "Consider removing this unused variable"

        case .class,
            .struct:
            "Consider removing this unused type"

        case .protocol:
            "Consider removing this unused protocol"

        case .import:
            "Consider removing this unused import"

        default:
            "Consider removing this unused declaration"
        }
    }

    /// Detect unused imports.
    private func detectUnusedImports(in result: AnalysisResult) -> [UnusedCode] {
        var unused: [UnusedCode] = []

        let imports = result.declarations.declarations.filter { $0.kind == .import }
        let referencedIdentifiers = Set(result.references.references.map(\.identifier))

        // Simple heuristic: if the import name isn't referenced anywhere
        // (This is a rough check - real import checking requires type resolution)
        for importDecl in imports where !referencedIdentifiers.contains(importDecl.name) {
            unused.append(
                UnusedCode(
                    declaration: importDecl,
                    reason: .importNotUsed,
                    confidence: .low,  // Low confidence without full type resolution
                    suggestion: "Consider removing unused import '\(importDecl.name)'",
                ))
        }

        return unused
    }
}
