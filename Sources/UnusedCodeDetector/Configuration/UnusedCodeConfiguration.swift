//
//  UnusedCodeConfiguration.swift
//  SwiftStaticAnalysis
//
//  Configuration for unused code detection.
//

import Foundation

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
        useParallelBFS: Bool = false,
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
        self.useParallelBFS = useParallelBFS
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

    // MARK: - Experimental Features

    /// Use experimental parallel BFS for reachability analysis (beta).
    ///
    /// This feature uses direction-optimizing parallel BFS (Beamer et al., 2012)
    /// for potentially faster reachability computation on large graphs.
    ///
    /// - Performance: 2-4x speedup on graphs with > 10,000 nodes
    /// - Small graphs: Minimal benefit due to parallelization overhead
    ///
    /// Enable via `--xparallel-bfs` CLI flag.
    public var useParallelBFS: Bool

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
