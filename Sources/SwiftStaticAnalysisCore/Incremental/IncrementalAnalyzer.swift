//  IncrementalAnalyzer.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - IncrementalConfiguration

/// Configuration for incremental analysis.
public struct IncrementalConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        cacheDirectory: URL? = nil,
        trackDependencies: Bool = true,
        changeDetection: ChangeDetector.Configuration = .default,
        concurrency: ConcurrencyConfiguration = .default,
    ) {
        self.cacheDirectory =
            cacheDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".swiftanalysis")
        self.trackDependencies = trackDependencies
        self.changeDetection = changeDetection
        self.concurrency = concurrency
    }

    // MARK: Public

    public static let `default` = Self()

    /// Configuration that disables caching (always full analysis).
    public static let disabled = Self(
        cacheDirectory: URL(fileURLWithPath: "/dev/null"),
        trackDependencies: false,
    )

    /// Directory for cache files.
    public let cacheDirectory: URL

    /// Whether to track dependencies for transitive invalidation.
    public let trackDependencies: Bool

    /// Change detector configuration.
    public let changeDetection: ChangeDetector.Configuration

    /// Concurrency configuration for parallel processing.
    public let concurrency: ConcurrencyConfiguration
}

// MARK: - IncrementalAnalysisResult

/// Result of incremental analysis.
public struct IncrementalAnalysisResult: Sendable {
    /// Full analysis result.
    public let result: AnalysisResult

    /// Files that were analyzed (not cached).
    public let analyzedFiles: [String]

    /// Files that were loaded from cache.
    public let cachedFiles: [String]

    /// Change detection result.
    public let changes: ChangeDetectionResult

    /// Time saved by using cache (estimated).
    public let timeSavedMs: Double

    /// Whether this was a full analysis (no cache).
    public var wasFullAnalysis: Bool {
        cachedFiles.isEmpty
    }

    /// Percentage of files from cache.
    public var cacheHitRate: Double {
        let total = analyzedFiles.count + cachedFiles.count
        return total > 0 ? Double(cachedFiles.count) / Double(total) * 100 : 0
    }
}

// MARK: - IncrementalAnalyzer

/// Performs incremental analysis by detecting changes and using cached results.
public actor IncrementalAnalyzer {
    // MARK: Lifecycle

    // MARK: - Initialization

    public init(configuration: IncrementalConfiguration = .default) {
        self.configuration = configuration
        cache = AnalysisCache(cacheDirectory: configuration.cacheDirectory)
        dependencyTracker = DependencyTracker(cacheDirectory: configuration.cacheDirectory)
        changeDetector = ChangeDetector(configuration: configuration.changeDetection)
        parser = SwiftFileParser()
    }

    // MARK: Public

    // MARK: - Diagnostics

    /// Diagnostic information about incremental analysis state.
    public struct Diagnostics: Sendable {
        public let cacheStats: AnalysisCache.Statistics
        public let dependencyStats: DependencyTracker.Statistics
        public let cacheDirectory: URL
    }

    /// Initialize caches by loading from disk.
    public func initialize() async throws {
        guard !isInitialized else { return }

        try await cache.load()
        if configuration.trackDependencies {
            try await dependencyTracker.load()
        }
        isInitialized = true
    }

    /// Save caches to disk.
    public func save() async throws {
        try await cache.save()
        if configuration.trackDependencies {
            try await dependencyTracker.save()
        }
    }

    // MARK: - Incremental Analysis

    /// Perform incremental analysis on the given files.
    ///
    /// - Parameter files: Files to analyze.
    /// - Returns: Incremental analysis result.
    public func analyze(  // swiftlint:disable:this function_body_length
        _ files: [String],
    ) async throws -> IncrementalAnalysisResult {
        try await initialize()

        let startTime = Date()

        // Step 1: Detect changes
        let previousState = await cache.getFileStates()
        let changes = await changeDetector.detectChanges(
            currentFiles: files,
            previousState: previousState,
        )

        // Step 2: Determine files to analyze
        var filesToAnalyze = Set(changes.filesToAnalyze)

        // Add transitively affected files if tracking dependencies
        if configuration.trackDependencies, !filesToAnalyze.isEmpty {
            let affected = await dependencyTracker.getAffectedFiles(changedFiles: filesToAnalyze)
            filesToAnalyze.formUnion(affected.intersection(Set(files)))
        }

        // Handle deleted files
        for file in changes.deletedFiles {
            await cache.removeFileState(for: file)
            await cache.removeDeclarations(for: file)
            await cache.removeReferences(for: file)
            await dependencyTracker.removeFile(file)
        }

        // Step 3: Load cached results for unchanged files
        let cachedFiles = files.filter { !filesToAnalyze.contains($0) }
        var cachedDeclarations: [Declaration] = []
        var cachedReferences: [Reference] = []

        for file in cachedFiles {
            let decls = await cache.getDeclarations(for: file)
            let refs = await cache.getReferences(for: file)

            // Convert cached data back to full objects
            cachedDeclarations.append(
                contentsOf: decls.map { cached in
                    let location = SourceLocation(
                        file: cached.file,
                        line: cached.line,
                        column: cached.column,
                        offset: cached.offset,
                    )
                    return Declaration(
                        name: cached.name,
                        kind: DeclarationKind(rawValue: cached.kind) ?? .variable,
                        accessLevel: AccessLevel(rawValue: cached.accessLevel) ?? .internal,
                        modifiers: DeclarationModifiers(rawValue: cached.modifiers),
                        location: location,
                        range: SourceRange(start: location, end: location),
                        scope: ScopeID(cached.scopeID),
                        typeAnnotation: cached.typeAnnotation,
                        documentation: cached.documentation,
                        conformances: cached.conformances,
                    )
                })

            cachedReferences.append(
                contentsOf: refs.map { cached in
                    Reference(
                        identifier: cached.identifier,
                        location: SourceLocation(
                            file: cached.file,
                            line: cached.line,
                            column: cached.column,
                            offset: cached.offset,
                        ),
                        scope: ScopeID(cached.scopeID),
                        context: ReferenceContext(rawValue: cached.context) ?? .unknown,
                        isQualified: cached.isQualified,
                        qualifier: cached.qualifier,
                    )
                })
        }

        // Step 4: Analyze changed files in parallel
        let filesToAnalyzeArray = Array(filesToAnalyze)
        var newDeclarations: [Declaration] = []
        var newReferences: [Reference] = []
        var newScopes: [Scope] = []
        var totalLines = 0

        if !filesToAnalyzeArray.isEmpty {
            let results = try await ParallelProcessor.map(
                filesToAnalyzeArray,
                maxConcurrency: configuration.concurrency.maxConcurrentFiles,
            ) { [parser] file -> FileAnalysisResult in
                let syntax = try await parser.parse(file)
                let lineCount = await parser.lineCount(for: file) ?? 0

                let declCollector = DeclarationCollector(file: file, tree: syntax)
                declCollector.walk(syntax)

                let refCollector = ReferenceCollector(file: file, tree: syntax)
                refCollector.walk(syntax)

                return FileAnalysisResult(
                    file: file,
                    declarations: declCollector.declarations + declCollector.imports,
                    references: refCollector.references,
                    scopes: Array(declCollector.tracker.tree.scopes.values),
                    lineCount: lineCount,
                )
            }

            // Aggregate results and update cache
            for result in results {
                newDeclarations.append(contentsOf: result.declarations)
                newReferences.append(contentsOf: result.references)
                newScopes.append(contentsOf: result.scopes)
                totalLines += result.lineCount

                // Update cache
                if let state = changeDetector.computeState(for: result.file) {
                    await cache.update(
                        file: result.file,
                        state: state,
                        declarations: result.declarations,
                        references: result.references,
                    )
                }

                // Update dependencies
                if configuration.trackDependencies {
                    var declarationIndex = DeclarationIndex()
                    for decl in newDeclarations + cachedDeclarations {
                        declarationIndex.add(decl)
                    }

                    let extractor = DependencyExtractor(declarationIndex: declarationIndex)
                    let dependencies = extractor.extractDependencies(
                        from: result.references,
                        in: result.file,
                    )
                    await dependencyTracker.updateDependencies(
                        for: result.file,
                        newDependencies: dependencies,
                    )
                }
            }
        }

        // Add line count for cached files (estimate)
        for file in cachedFiles {
            if let state = await cache.getFileState(for: file) {
                // Rough estimate: ~30 bytes per line
                totalLines += Int(state.size / 30)
            }
        }

        // Step 5: Build combined result
        let allDeclarations = newDeclarations + cachedDeclarations
        let allReferences = newReferences + cachedReferences

        var declarationIndex = DeclarationIndex()
        var referenceIndex = ReferenceIndex()
        var scopeTree = ScopeTree()
        var declarationsByKind: [String: Int] = [:]

        for decl in allDeclarations {
            declarationIndex.add(decl)
            declarationsByKind[decl.kind.rawValue, default: 0] += 1
        }

        for ref in allReferences {
            referenceIndex.add(ref)
        }

        for scope in newScopes {
            scopeTree.add(scope)
        }

        let analysisTime = Date().timeIntervalSince(startTime)

        // Estimate time saved (rough: ~10ms per cached file)
        let timeSaved = Double(cachedFiles.count) * 10.0

        let statistics = AnalysisStatistics(
            fileCount: files.count,
            totalLines: totalLines,
            declarationCount: declarationIndex.declarations.count,
            referenceCount: referenceIndex.references.count,
            declarationsByKind: declarationsByKind,
            analysisTime: analysisTime,
        )

        let analysisResult = AnalysisResult(
            files: files,
            declarations: declarationIndex,
            references: referenceIndex,
            scopes: scopeTree,
            statistics: statistics,
        )

        return IncrementalAnalysisResult(
            result: analysisResult,
            analyzedFiles: filesToAnalyzeArray,
            cachedFiles: cachedFiles,
            changes: changes,
            timeSavedMs: timeSaved,
        )
    }

    // MARK: - Cache Management

    /// Clear all caches.
    public func clearCache() async {
        await cache.clear()
        await dependencyTracker.clear()
    }

    /// Delete cache files from disk.
    public func deleteCache() async throws {
        try await cache.delete()
    }

    /// Get cache statistics.
    public func cacheStatistics() async -> AnalysisCache.Statistics {
        await cache.statistics()
    }

    /// Get dependency statistics.
    public func dependencyStatistics() async -> DependencyTracker.Statistics {
        await dependencyTracker.statistics()
    }

    /// Get diagnostic information.
    public func diagnostics() async -> Diagnostics {
        await Diagnostics(
            cacheStats: cache.statistics(),
            dependencyStats: dependencyTracker.statistics(),
            cacheDirectory: configuration.cacheDirectory,
        )
    }

    // MARK: Private

    /// Configuration.
    private let configuration: IncrementalConfiguration

    /// Analysis cache.
    private let cache: AnalysisCache

    /// Dependency tracker.
    private let dependencyTracker: DependencyTracker

    /// Change detector.
    private let changeDetector: ChangeDetector

    /// File parser.
    private let parser: SwiftFileParser

    /// Whether caches have been loaded.
    private var isInitialized: Bool = false
}

// FileAnalysisResult is defined in Models/AnalysisResult.swift
