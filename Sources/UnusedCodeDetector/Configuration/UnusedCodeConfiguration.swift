//  UnusedCodeConfiguration.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore

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
        mode: DetectionMode = .reachability,
        indexStorePath: String? = nil,
        minimumConfidence: Confidence = .medium,
        ignoredPatterns: [String] = [],
        treatPublicAsRoot: Bool = true,
        treatObjcAsRoot: Bool = true,
        treatTestsAsRoot: Bool = true,
        autoBuild: Bool = false,
        allowsIndexDatabaseCreation: Bool = true,
        sandboxRootPath: String? = nil,
        hybridMode: Bool = false,
        warnOnStaleIndex: Bool = true,
        useIncremental: Bool = false,
        cacheDirectory: URL? = nil,
        treatSwiftUIViewsAsRoot: Bool = true,
        ignoreSwiftUIPropertyWrappers: Bool = true,
        ignorePreviewProviders: Bool = true,
        ignoreViewBody: Bool = true,
        useParallelBFS: Bool? = nil,
        parallelBFSThreshold: Int = 1000,
        logger: AnalysisLogger = .osLog(category: "UnusedCodeDetector"),
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
        self.allowsIndexDatabaseCreation = allowsIndexDatabaseCreation
        self.sandboxRootPath = sandboxRootPath
        self.hybridMode = hybridMode
        self.warnOnStaleIndex = warnOnStaleIndex
        self.useIncremental = useIncremental
        self.cacheDirectory = cacheDirectory
        self.treatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot
        self.ignoreSwiftUIPropertyWrappers = ignoreSwiftUIPropertyWrappers
        self.ignorePreviewProviders = ignorePreviewProviders
        self.ignoreViewBody = ignoreViewBody
        self.useParallelBFS = useParallelBFS
        self.parallelBFSThreshold = max(1, parallelBFSThreshold)
        self.logger = logger
    }

    // MARK: Public

    /// Default configuration.
    public static let `default` = Self()

    /// Reachability-based configuration.
    public static let reachability = Self(mode: .reachability)

    /// IndexStore-based configuration (most accurate).
    public static let indexStore = Self(mode: .indexStore)

    /// IndexStore with auto-build enabled.
    public static let indexStoreAutoBuild = Self(
        mode: .indexStore,
        autoBuild: true,
    )

    /// Hybrid mode configuration.
    public static let hybrid = Self(
        mode: .indexStore,
        hybridMode: true,
    )

    /// Strict configuration (catches more potential issues).
    public static let strict = Self(
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

    /// When `true`, `IndexStoreReader.init` may create the sibling
    /// `IndexDatabase/` directory next to the index store. Defaults to
    /// `true` so direct programmatic and CLI use is unchanged. The MCP
    /// path sets this to `false` so a hostile prompt cannot drive a
    /// filesystem-write side effect at an attacker-chosen location,
    /// even after the path-validation gate in `handleDetectUnusedCode`.
    public var allowsIndexDatabaseCreation: Bool

    /// When non-nil, sandboxed callers (notably the MCP server) supply
    /// the codebase root here. The IndexStore fallback layer
    /// re-validates every derived path it touches against this root
    /// (canonical, separator-aware prefix check), closing the TOCTOU
    /// window between the initial `CodebaseContext.validatePath` and
    /// the fallback's subsequent filesystem operations.
    public var sandboxRootPath: String?

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

    /// Use parallel BFS for reachability analysis.
    ///
    /// This feature uses direction-optimizing parallel BFS (Beamer et al., 2012)
    /// for faster reachability computation on large graphs.
    ///
    /// - Performance: 2-4x speedup on graphs with > 10,000 nodes
    /// - Small graphs: Minimal benefit due to parallelization overhead
    ///
    /// Override for the parallel-BFS routing decision.
    ///
    /// - `nil` (default) — auto-select based on `parallelBFSThreshold`:
    ///   graphs with `>= threshold` nodes use `computeUnreachableParallel`,
    ///   smaller graphs stay sequential.
    /// - `true` — force parallel BFS regardless of size.
    /// - `false` — force sequential BFS regardless of size.
    public var useParallelBFS: Bool?

    /// Node-count threshold above which the auto-select path uses
    /// parallel BFS. Only consulted when `useParallelBFS == nil`.
    /// Default 1000 matches the documented contract.
    public var parallelBFSThreshold: Int

    /// Logger used for warnings and fallback notices in library code.
    public var logger: AnalysisLogger

    /// Use IndexStoreDB for accurate detection (deprecated, use mode instead).
    @available(*, deprecated, message: "Use mode = .indexStore instead")
    public var useIndexStore: Bool {
        get { mode == .indexStore }
        set { if newValue { mode = .indexStore } }
    }

    /// Incremental configuration with caching enabled.
    public static func incremental(cacheDirectory: URL? = nil) -> Self {
        Self(
            mode: .reachability,
            useIncremental: true,
            cacheDirectory: cacheDirectory,
        )
    }
}
