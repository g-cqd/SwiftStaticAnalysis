//
//  UnusedCodeDetector.swift
//  SwiftStaticAnalysis
//
//  Unused code detection module.
//

import Foundation
import IndexStoreDB
import SwiftStaticAnalysisCore

// MARK: - UnusedReason

/// Reasons why code is considered unused.
public enum UnusedReason: String, Sendable, Codable {
    /// Declaration is never referenced anywhere.
    case neverReferenced

    /// Variable is assigned but never read.
    case onlyAssigned

    /// Only referenced within its own implementation.
    case onlySelfReferenced

    /// Import statement is not used.
    case importNotUsed

    /// Parameter is never used in function body.
    case parameterUnused
}

// MARK: - Confidence

/// Confidence level for unused code detection.
public enum Confidence: String, Sendable, Codable, Comparable {
    /// Definitely unused (private, no references found).
    case high

    /// Likely unused (internal, no visible references).
    case medium

    /// Possibly unused (public API, may be used externally).
    case low

    // MARK: Public

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rank < rhs.rank
    }

    // MARK: Private

    private var rank: Int {
        switch self {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }
}

// MARK: - UnusedCode

/// Represents a piece of unused code.
public struct UnusedCode: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        declaration: Declaration,
        reason: UnusedReason,
        confidence: Confidence,
        suggestion: String = "Consider removing this declaration",
    ) {
        self.declaration = declaration
        self.reason = reason
        self.confidence = confidence
        self.suggestion = suggestion
    }

    // MARK: Public

    /// The unused declaration.
    public let declaration: Declaration

    /// Reason it's considered unused.
    public let reason: UnusedReason

    /// Confidence level.
    public let confidence: Confidence

    /// Suggested action.
    public let suggestion: String
}

// MARK: - DetectionMode

/// Mode for unused code detection.
public enum DetectionMode: String, Sendable, Codable {
    /// Simple reference counting (fast, approximate).
    case simple

    /// Reachability graph analysis (more accurate, considers entry points).
    case reachability

    /// IndexStoreDB-based (most accurate, requires project build).
    case indexStore
}

// MARK: - UnusedCodeConfiguration

/// Configuration for unused code detection.
public struct UnusedCodeConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        detectVariables: Bool = true,
        detectFunctions: Bool = true,
        detectTypes: Bool = true,
        detectImports: Bool = true,
        detectParameters: Bool = true,
        ignorePublicAPI: Bool = true,
        mode: DetectionMode = .simple,
        indexStorePath: String? = nil,
        minimumConfidence: Confidence = .medium,
        ignoredPatterns: [String] = [],
        treatPublicAsRoot: Bool = true,
        treatObjcAsRoot: Bool = true,
        treatTestsAsRoot: Bool = true,
        autoBuild: Bool = false,
        hybridMode: Bool = false,
        warnOnStaleIndex: Bool = true,
        useIncremental: Bool = false,
        cacheDirectory: URL? = nil,
        treatSwiftUIViewsAsRoot: Bool = true,
        ignoreSwiftUIPropertyWrappers: Bool = true,
        ignorePreviewProviders: Bool = true,
        ignoreViewBody: Bool = true,
    ) {
        self.detectVariables = detectVariables
        self.detectFunctions = detectFunctions
        self.detectTypes = detectTypes
        self.detectImports = detectImports
        self.detectParameters = detectParameters
        self.ignorePublicAPI = ignorePublicAPI
        self.mode = mode
        self.indexStorePath = indexStorePath
        self.minimumConfidence = minimumConfidence
        self.ignoredPatterns = ignoredPatterns
        self.treatPublicAsRoot = treatPublicAsRoot
        self.treatObjcAsRoot = treatObjcAsRoot
        self.treatTestsAsRoot = treatTestsAsRoot
        self.autoBuild = autoBuild
        self.hybridMode = hybridMode
        self.warnOnStaleIndex = warnOnStaleIndex
        self.useIncremental = useIncremental
        self.cacheDirectory = cacheDirectory
        self.treatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot
        self.ignoreSwiftUIPropertyWrappers = ignoreSwiftUIPropertyWrappers
        self.ignorePreviewProviders = ignorePreviewProviders
        self.ignoreViewBody = ignoreViewBody
    }

    // MARK: Public

    /// Default configuration.
    public static let `default` = UnusedCodeConfiguration()

    /// Reachability-based configuration.
    public static let reachability = UnusedCodeConfiguration(mode: .reachability)

    /// IndexStore-based configuration (most accurate).
    public static let indexStore = UnusedCodeConfiguration(mode: .indexStore)

    /// IndexStore with auto-build enabled.
    public static let indexStoreAutoBuild = UnusedCodeConfiguration(
        mode: .indexStore,
        autoBuild: true,
    )

    /// Hybrid mode configuration.
    public static let hybrid = UnusedCodeConfiguration(
        mode: .indexStore,
        hybridMode: true,
    )

    /// Strict configuration (catches more potential issues).
    public static let strict = UnusedCodeConfiguration(
        ignorePublicAPI: false,
        mode: .reachability,
        minimumConfidence: .low,
        treatPublicAsRoot: false,
    )

    /// Detect unused variables.
    public var detectVariables: Bool

    /// Detect unused functions.
    public var detectFunctions: Bool

    /// Detect unused types.
    public var detectTypes: Bool

    /// Detect unused imports.
    public var detectImports: Bool

    /// Detect unused parameters.
    public var detectParameters: Bool

    /// Ignore public API (may be used externally).
    public var ignorePublicAPI: Bool

    /// Detection mode to use.
    public var mode: DetectionMode

    /// Path to the index store (usually .build/...).
    public var indexStorePath: String?

    /// Minimum confidence level to report.
    public var minimumConfidence: Confidence

    /// Patterns to ignore (regex for declaration names).
    public var ignoredPatterns: [String]

    /// Treat public API as entry points (for reachability mode).
    public var treatPublicAsRoot: Bool

    /// Treat @objc declarations as entry points.
    public var treatObjcAsRoot: Bool

    /// Treat test methods as entry points.
    public var treatTestsAsRoot: Bool

    /// Automatically build the project if index store is missing/stale.
    public var autoBuild: Bool

    /// Use hybrid mode (index for cross-module, syntax for local).
    public var hybridMode: Bool

    /// Warn when using a stale index.
    public var warnOnStaleIndex: Bool

    // MARK: - Incremental Analysis Configuration

    /// Enable incremental analysis with caching.
    public var useIncremental: Bool

    /// Cache directory for incremental analysis.
    public var cacheDirectory: URL?

    // MARK: - SwiftUI Configuration

    /// Treat SwiftUI Views as entry points (body is always used).
    public var treatSwiftUIViewsAsRoot: Bool

    /// Ignore SwiftUI property wrappers (@State, @Binding, etc.).
    public var ignoreSwiftUIPropertyWrappers: Bool

    /// Ignore PreviewProvider implementations.
    public var ignorePreviewProviders: Bool

    /// Ignore View body properties.
    public var ignoreViewBody: Bool

    /// Use IndexStoreDB for accurate detection (deprecated, use mode instead).
    @available(*, deprecated, message: "Use mode = .indexStore instead")
    public var useIndexStore: Bool {
        get { mode == .indexStore }
        set { if newValue { mode = .indexStore } }
    }

    /// Incremental configuration with caching enabled.
    public static func incremental(cacheDirectory: URL? = nil) -> UnusedCodeConfiguration {
        UnusedCodeConfiguration(
            mode: .reachability,
            useIncremental: true,
            cacheDirectory: cacheDirectory,
        )
    }
}

// MARK: - UnusedCodeDetector

/// Detects unused code in Swift source files.
public struct UnusedCodeDetector: Sendable {
    // MARK: Lifecycle

    public init(configuration: UnusedCodeConfiguration = .default) {
        self.configuration = configuration
        analyzer = StaticAnalyzer()
    }

    // MARK: Public

    /// Configuration for detection.
    public let configuration: UnusedCodeConfiguration

    /// Detect unused code in the given files.
    ///
    /// - Parameter files: Array of Swift file paths.
    /// - Returns: Array of unused code findings.
    public func detectUnused(in files: [String]) async throws -> [UnusedCode] {
        switch configuration.mode {
        case .simple:
            try await detectUnusedWithSyntax(in: files)

        case .reachability:
            try await detectUnusedWithReachability(in: files)

        case .indexStore:
            try await detectUnusedWithIndexStore(in: files)
        }
    }

    /// Detect unused code from source string (for testing).
    ///
    /// - Parameters:
    ///   - source: Swift source code string.
    ///   - file: Virtual file name for reporting.
    /// - Returns: Array of unused code findings.
    public func detectFromSource(_ source: String, file: String) async throws -> [UnusedCode] {
        // Parse the source
        let result = try await analyzer.analyzeSource(source, file: file)

        switch configuration.mode {
        case .simple:
            return detectFromResult(result)

        case .reachability:
            let extractionConfig = DependencyExtractionConfiguration(
                treatPublicAsRoot: configuration.treatPublicAsRoot,
                treatObjcAsRoot: configuration.treatObjcAsRoot,
                treatTestsAsRoot: configuration.treatTestsAsRoot,
            )
            let reachabilityDetector = ReachabilityBasedDetector(
                configuration: configuration,
                extractionConfiguration: extractionConfig,
            )
            return reachabilityDetector.detect(in: result)

        case .indexStore:
            // For source strings, fall back to simple mode
            return detectFromResult(result)
        }
    }

    /// Generate a reachability report for the given files.
    ///
    /// - Parameter files: Array of Swift file paths.
    /// - Returns: A reachability report.
    public func generateReachabilityReport(for files: [String]) async throws -> ReachabilityReport {
        let result = try await analyzer.analyze(files)

        let extractionConfig = DependencyExtractionConfiguration(
            treatPublicAsRoot: configuration.treatPublicAsRoot,
            treatObjcAsRoot: configuration.treatObjcAsRoot,
            treatTestsAsRoot: configuration.treatTestsAsRoot,
        )

        let reachabilityDetector = ReachabilityBasedDetector(
            configuration: configuration,
            extractionConfiguration: extractionConfig,
        )

        return reachabilityDetector.generateReport(for: result)
    }

    // MARK: Private

    /// The analyzer for parsing files.
    private let analyzer: StaticAnalyzer

    /// Detect unused code using reachability graph analysis.
    private func detectUnusedWithReachability(in files: [String]) async throws -> [UnusedCode] {
        // Analyze all files
        let result = try await analyzer.analyze(files)

        // Configure the reachability detector
        let extractionConfig = DependencyExtractionConfiguration(
            treatPublicAsRoot: configuration.treatPublicAsRoot,
            treatObjcAsRoot: configuration.treatObjcAsRoot,
            treatTestsAsRoot: configuration.treatTestsAsRoot,
            treatProtocolRequirementsAsRoot: true,
            trackProtocolWitnesses: true,
            trackClosureCaptures: true,
        )

        let reachabilityDetector = ReachabilityBasedDetector(
            configuration: configuration,
            extractionConfiguration: extractionConfig,
        )

        // Get unreachable code
        var unusedItems = reachabilityDetector.detect(in: result)

        // Also check for imports if enabled
        if configuration.detectImports {
            let unusedImports = detectUnusedImports(result: result)
            unusedItems.append(contentsOf: unusedImports)
        }

        return unusedItems
            .filter { $0.confidence >= configuration.minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Detect unused code using IndexStoreDB (accurate but requires project build).
    private func detectUnusedWithIndexStore(in files: [String]) async throws -> [UnusedCode] {
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
        case let .indexStore(db, _):
            // Use index-based dependency graph
            return detectWithIndexGraph(db: db, files: files)

        case let .hybrid(db, _):
            // Combine index and syntax analysis
            return try await detectWithHybridMode(db: db, files: files)

        case let .reachability(reason):
            // Log the reason and fall back
            if configuration.warnOnStaleIndex {
                print("Note: \(reason.description)")
                print("Falling back to reachability-based analysis.")
            }
            return try await detectUnusedWithReachability(in: files)
        }
    }

    /// Detect unused code using the index-based dependency graph.
    private func detectWithIndexGraph(db: IndexStoreDB, files: [String]) -> [UnusedCode] {
        // Configure the graph
        let graphConfig = IndexGraphConfiguration(
            treatTestsAsRoot: configuration.treatTestsAsRoot,
            treatProtocolRequirementsAsRoot: true,
            includeCrossModuleEdges: true,
            trackProtocolWitnesses: true,
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
                accessLevel: .internal, // Not available from index
                modifiers: [],
                location: location,
                range: SourceRange(start: location, end: location),
                scope: .global,
            )

            return UnusedCode(
                declaration: declaration,
                reason: .neverReferenced,
                confidence: .high, // High confidence from index analysis
                suggestion: "Unreachable symbol '\(node.name)' - consider removing",
            )
        }
        .filter { $0.confidence >= configuration.minimumConfidence }
        .sorted { $0.confidence > $1.confidence }
    }

    /// Detect unused code using hybrid mode (index + syntax).
    private func detectWithHybridMode(db: IndexStoreDB, files: [String]) async throws -> [UnusedCode] {
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
        for result in syntaxResults {
            if resultsByName[result.declaration.name] == nil {
                resultsByName[result.declaration.name] = result
            }
        }

        return Array(resultsByName.values)
            .filter { $0.confidence >= configuration.minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Check if an index node should be reported.
    private func shouldReportIndexNode(_ node: IndexSymbolNode) -> Bool {
        let filter = DeclarationKindFilter(
            detectVariables: configuration.detectVariables,
            detectFunctions: configuration.detectFunctions,
            detectTypes: configuration.detectTypes,
            detectParameters: configuration.detectParameters,
        )
        return filter.shouldReport(node.kind.toDeclarationKind())
    }

    /// Convert index kind to declaration kind.
    private func convertIndexKind(_ kind: IndexedSymbolKind) -> DeclarationKind {
        kind.toDeclarationKind()
    }

    /// Find the project root for the given files.
    private func findProjectRoot(for files: [String]) -> String? {
        guard let firstFile = files.first else { return nil }

        var current = URL(fileURLWithPath: firstFile).deletingLastPathComponent()
        let maxDepth = 10

        for _ in 0 ..< maxDepth {
            // Check for Package.swift (Swift package)
            let packageSwift = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return current.path
            }

            // Check for .xcodeproj or .xcworkspace
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
               contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                return current.path
            }

            current = current.deletingLastPathComponent()
        }

        return nil
    }

    /// Find the index store path for the given files.
    private func findIndexStorePath(for files: [String]) -> String? {
        guard let firstFile = files.first else { return nil }

        // Walk up from the first file to find project root
        var current = URL(fileURLWithPath: firstFile).deletingLastPathComponent()
        let maxDepth = 10

        for _ in 0 ..< maxDepth {
            // Check for Package.swift (Swift package)
            let packageSwift = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return IndexStorePathFinder.findIndexStorePath(in: current.path)
            }

            // Check for .xcodeproj
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
               contents.contains(where: { $0.hasSuffix(".xcodeproj") }) {
                return IndexStorePathFinder.findIndexStorePath(in: current.path)
            }

            current = current.deletingLastPathComponent()
        }

        return nil
    }

    /// Detect unused code using SwiftSyntax only (fast but approximate).
    private func detectUnusedWithSyntax(in files: [String]) async throws -> [UnusedCode] {
        // Analyze all files
        let result = try await analyzer.analyze(files)

        var unusedItems: [UnusedCode] = []

        // Build a set of all referenced identifiers
        let referencedIdentifiers = result.references.uniqueIdentifiers

        // Check each declaration
        for declaration in result.declarations.declarations {
            // Skip based on configuration
            if !shouldCheck(declaration) {
                continue
            }

            // Check if referenced
            let isReferenced = referencedIdentifiers.contains(declaration.name)

            if !isReferenced {
                let confidence = declaration.unusedConfidence

                // Skip if below minimum confidence
                if confidence < configuration.minimumConfidence {
                    continue
                }

                let reason = determineReason(for: declaration, result: result)
                let suggestion = generateSuggestion(for: declaration, reason: reason)

                unusedItems.append(UnusedCode(
                    declaration: declaration,
                    reason: reason,
                    confidence: confidence,
                    suggestion: suggestion,
                ))
            }
        }

        // Check imports if enabled
        if configuration.detectImports {
            let unusedImports = detectUnusedImports(result: result)
            unusedItems.append(contentsOf: unusedImports)
        }

        return unusedItems.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Private Helpers

    private func shouldCheck(_ declaration: Declaration) -> Bool {
        // Check if this kind should be detected
        switch declaration.kind {
        case .constant,
             .variable:
            guard configuration.detectVariables else { return false }
        case .function,
             .method:
            guard configuration.detectFunctions else { return false }
        case .class,
             .enum,
             .protocol,
             .struct:
            guard configuration.detectTypes else { return false }

        case .parameter:
            guard configuration.detectParameters else { return false }

        case .import:
            return false // Handled separately
        default:
            break
        }

        // Check if public API should be ignored
        if configuration.ignorePublicAPI, declaration.accessLevel >= .public {
            return false
        }

        // Check for entry point attributes (@main, @UIApplicationMain, @NSApplicationMain)
        let entryPointAttributes = ["main", "UIApplicationMain", "NSApplicationMain"]
        if declaration.attributes.contains(where: { entryPointAttributes.contains($0) }) {
            return false
        }

        // MARK: - SwiftUI-specific exclusions

        // Ignore SwiftUI property wrappers (@State, @Binding, etc.)
        if configuration.ignoreSwiftUIPropertyWrappers {
            if declaration.hasImplicitUsageWrapper {
                return false
            }
        }

        // Ignore SwiftUI View types
        if configuration.treatSwiftUIViewsAsRoot {
            if declaration.isSwiftUIView {
                return false
            }
        }

        // Ignore PreviewProvider implementations
        if configuration.ignorePreviewProviders {
            if declaration.isSwiftUIPreview {
                return false
            }
        }

        // Ignore View body computed property
        if configuration.ignoreViewBody {
            if declaration.name == "body", declaration.kind == .variable {
                // Check if parent scope is a View type
                // For now, just check if the name is "body"
                return false
            }
        }

        // Check ignored patterns
        for pattern in configuration.ignoredPatterns {
            if let regex = try? Regex(pattern),
               declaration.name.contains(regex) {
                return false
            }
        }

        return true
    }

    private func determineReason(
        for declaration: Declaration,
        result: AnalysisResult,
    ) -> UnusedReason {
        switch declaration.kind {
        case .constant,
             .variable:
            // Check if only written to
            let refs = result.references.find(identifier: declaration.name)
            let hasReads = refs.contains { $0.context == .read }
            if !hasReads, refs.contains(where: { $0.context == .write }) {
                return .onlyAssigned
            }
            return .neverReferenced

        case .parameter:
            return .parameterUnused

        case .import:
            return .importNotUsed

        default:
            return .neverReferenced
        }
    }

    private func generateSuggestion(
        for declaration: Declaration,
        reason: UnusedReason,
    ) -> String {
        switch reason {
        case .neverReferenced:
            "Consider removing unused \(declaration.kind.rawValue) '\(declaration.name)'"

        case .onlyAssigned:
            "Variable '\(declaration.name)' is assigned but never read"

        case .onlySelfReferenced:
            "'\(declaration.name)' is only used within its own implementation"

        case .importNotUsed:
            "Import '\(declaration.name)' is not used"

        case .parameterUnused:
            "Parameter '\(declaration.name)' is never used; consider renaming to '_'"
        }
    }

    private func detectUnusedImports(result: AnalysisResult) -> [UnusedCode] {
        var unusedImports: [UnusedCode] = []

        // Get all import declarations
        let imports = result.declarations.find(kind: .import)

        // For each import, check if any reference uses that module
        for importDecl in imports {
            let moduleName = importDecl.name

            // Check if any type reference might be from this module
            // This is approximate without semantic analysis
            let potentiallyUsed = result.references.references.contains { ref in
                ref.context == .typeAnnotation ||
                    ref.context == .inheritance ||
                    ref.context == .call
            }

            // For now, mark as low confidence since we can't be certain
            if !potentiallyUsed {
                unusedImports.append(UnusedCode(
                    declaration: importDecl,
                    reason: .importNotUsed,
                    confidence: .low,
                    suggestion: "Import '\(moduleName)' may not be used",
                ))
            }
        }

        return unusedImports
    }

    /// Detect unused code from an analysis result (simple mode).
    private func detectFromResult(_ result: AnalysisResult) -> [UnusedCode] {
        var unusedItems: [UnusedCode] = []

        // Build a set of all referenced identifiers
        let referencedIdentifiers = result.references.uniqueIdentifiers

        // Check each declaration
        for declaration in result.declarations.declarations {
            // Skip based on configuration
            if !shouldCheck(declaration) {
                continue
            }

            // Check if referenced
            let isReferenced = referencedIdentifiers.contains(declaration.name)

            if !isReferenced {
                let confidence = declaration.unusedConfidence

                // Skip if below minimum confidence
                if confidence < configuration.minimumConfidence {
                    continue
                }

                let reason = determineReason(for: declaration, result: result)
                let suggestion = generateSuggestion(for: declaration, reason: reason)

                unusedItems.append(UnusedCode(
                    declaration: declaration,
                    reason: reason,
                    confidence: confidence,
                    suggestion: suggestion,
                ))
            }
        }

        return unusedItems.sorted { $0.confidence > $1.confidence }
    }
}

// MARK: - UnusedCodeReport

/// Report summarizing unused code findings.
public struct UnusedCodeReport: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        filesAnalyzed: Int,
        totalDeclarations: Int,
        unusedItems: [UnusedCode],
    ) {
        self.filesAnalyzed = filesAnalyzed
        self.totalDeclarations = totalDeclarations
        self.unusedItems = unusedItems
    }

    // MARK: Public

    /// Total files analyzed.
    public let filesAnalyzed: Int

    /// Total declarations analyzed.
    public let totalDeclarations: Int

    /// Unused code items found.
    public let unusedItems: [UnusedCode]

    /// Summary by kind.
    public var summaryByKind: [String: Int] {
        var summary: [String: Int] = [:]
        for item in unusedItems {
            summary[item.declaration.kind.rawValue, default: 0] += 1
        }
        return summary
    }

    /// Summary by confidence.
    public var summaryByConfidence: [String: Int] {
        var summary: [String: Int] = [:]
        for item in unusedItems {
            summary[item.confidence.rawValue, default: 0] += 1
        }
        return summary
    }
}
