// swiftlint:disable discouraged_optional_boolean
//
//  SWAConfiguration.swift
//  SwiftStaticAnalysis
//
//  Configuration file model for SwiftStaticAnalysis.
//  Supports JSON configuration files (.swa.json) for project-level settings.
//
//  Note: Optional booleans are intentional for partial configuration support.
//  Config files may omit values that should use defaults.
//

import Foundation

// MARK: - SWAConfiguration

/// Root configuration structure for SwiftStaticAnalysis.
///
/// This configuration can be loaded from a `.swa.json` file in the project root.
/// All fields are optional - missing values use built-in defaults.
///
/// Example `.swa.json`:
/// ```json
/// {
///   "version": 1,
///   "format": "xcode",
///   "excludePaths": ["**/Tests/**", "**/Fixtures/**"],
///   "unused": {
///     "enabled": true,
///     "mode": "reachability"
///   },
///   "duplicates": {
///     "enabled": true,
///     "minTokens": 50
///   }
/// }
/// ```
public struct SWAConfiguration: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        version: Int = 1,
        format: String? = nil,
        excludePaths: [String]? = nil,
        unused: UnusedConfiguration? = nil,
        duplicates: DuplicatesConfiguration? = nil,
    ) {
        self.version = version
        self.format = format
        self.excludePaths = excludePaths
        self.unused = unused
        self.duplicates = duplicates
    }

    // MARK: Public

    /// Default configuration with sensible defaults.
    public static let `default` = Self()

    /// Configuration file format version.
    public var version: Int

    /// Global output format: "text", "json", or "xcode".
    public var format: String?

    /// Global path exclusion patterns (glob syntax).
    public var excludePaths: [String]?

    /// Unused code detection configuration.
    public var unused: UnusedConfiguration?

    /// Duplication detection configuration.
    public var duplicates: DuplicatesConfiguration?
}

// MARK: - UnusedConfiguration

/// Configuration for unused code detection.
public struct UnusedConfiguration: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        enabled: Bool? = nil,
        mode: String? = nil,
        indexStorePath: String? = nil,
        minConfidence: String? = nil,
        treatPublicAsRoot: Bool? = nil,
        treatObjcAsRoot: Bool? = nil,
        treatTestsAsRoot: Bool? = nil,
        treatSwiftUIViewsAsRoot: Bool? = nil,
        ignoreSwiftUIPropertyWrappers: Bool? = nil,
        ignorePreviewProviders: Bool? = nil,
        ignoreViewBody: Bool? = nil,
        ignorePublicAPI: Bool? = nil,
        sensibleDefaults: Bool? = nil,
        excludeImports: Bool? = nil,
        excludeDeinit: Bool? = nil,
        excludeEnumCases: Bool? = nil,
        excludeTestSuites: Bool? = nil,
        excludeNamePatterns: [String]? = nil,
        excludePaths: [String]? = nil,
    ) {
        self.enabled = enabled
        self.mode = mode
        self.indexStorePath = indexStorePath
        self.minConfidence = minConfidence
        self.treatPublicAsRoot = treatPublicAsRoot
        self.treatObjcAsRoot = treatObjcAsRoot
        self.treatTestsAsRoot = treatTestsAsRoot
        self.treatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot
        self.ignoreSwiftUIPropertyWrappers = ignoreSwiftUIPropertyWrappers
        self.ignorePreviewProviders = ignorePreviewProviders
        self.ignoreViewBody = ignoreViewBody
        self.ignorePublicAPI = ignorePublicAPI
        self.sensibleDefaults = sensibleDefaults
        self.excludeImports = excludeImports
        self.excludeDeinit = excludeDeinit
        self.excludeEnumCases = excludeEnumCases
        self.excludeTestSuites = excludeTestSuites
        self.excludeNamePatterns = excludeNamePatterns
        self.excludePaths = excludePaths
    }

    // MARK: Public

    /// Default configuration with all options as nil (use detector defaults).
    public static let `default` = Self()

    /// Whether unused code detection is enabled (default: true).
    public var enabled: Bool?

    /// Detection mode: "simple", "reachability", or "indexStore".
    public var mode: String?

    /// Path to IndexStore for indexStore mode.
    public var indexStorePath: String?

    /// Minimum confidence level: "low", "medium", or "high".
    public var minConfidence: String?

    /// Treat public API as entry points.
    public var treatPublicAsRoot: Bool?

    /// Treat @objc declarations as entry points.
    public var treatObjcAsRoot: Bool?

    /// Treat test methods as entry points.
    public var treatTestsAsRoot: Bool?

    /// Treat SwiftUI Views as entry points.
    public var treatSwiftUIViewsAsRoot: Bool?

    /// Ignore SwiftUI property wrappers (@State, @Binding, etc.).
    public var ignoreSwiftUIPropertyWrappers: Bool?

    /// Ignore PreviewProvider implementations.
    public var ignorePreviewProviders: Bool?

    /// Ignore View body properties.
    public var ignoreViewBody: Bool?

    /// Ignore public API (may be used externally).
    public var ignorePublicAPI: Bool?

    /// Apply sensible defaults for common exclusions.
    public var sensibleDefaults: Bool?

    /// Exclude import statements from analysis.
    public var excludeImports: Bool?

    /// Exclude deinit methods from analysis.
    public var excludeDeinit: Bool?

    /// Exclude backticked enum cases from analysis.
    public var excludeEnumCases: Bool?

    /// Exclude test suite declarations from analysis.
    public var excludeTestSuites: Bool?

    /// Regex patterns for declaration names to exclude.
    public var excludeNamePatterns: [String]?

    /// Additional path exclusion patterns (glob syntax).
    public var excludePaths: [String]?
}

// MARK: - DuplicatesConfiguration

/// Configuration for duplication detection.
public struct DuplicatesConfiguration: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        enabled: Bool? = nil,
        minTokens: Int? = nil,
        minSimilarity: Double? = nil,
        types: [String]? = nil,
        algorithm: String? = nil,
        ignoredPatterns: [String]? = nil,
        excludePaths: [String]? = nil,
    ) {
        self.enabled = enabled
        self.minTokens = minTokens
        self.minSimilarity = minSimilarity
        self.types = types
        self.algorithm = algorithm
        self.ignoredPatterns = ignoredPatterns
        self.excludePaths = excludePaths
    }

    // MARK: Public

    /// Default configuration with all options as nil (use detector defaults).
    public static let `default` = Self()

    /// Whether duplication detection is enabled (default: true).
    public var enabled: Bool?

    /// Minimum tokens for clone detection (default: 50).
    public var minTokens: Int?

    /// Minimum similarity for near/semantic clones (0.0-1.0, default: 0.8).
    public var minSimilarity: Double?

    /// Clone types to detect: "exact", "near", "semantic".
    public var types: [String]?

    /// Detection algorithm: "rollingHash", "suffixArray", "minHashLSH".
    public var algorithm: String?

    /// Regex patterns for code to ignore.
    public var ignoredPatterns: [String]?

    /// Additional path exclusion patterns (glob syntax).
    public var excludePaths: [String]?
}

// MARK: - SWAConfiguration.CodingKeys

extension SWAConfiguration {
    enum CodingKeys: String, CodingKey {
        case version
        case format
        case excludePaths
        case unused
        case duplicates
    }
}

// MARK: - UnusedConfiguration.CodingKeys

extension UnusedConfiguration {
    enum CodingKeys: String, CodingKey {
        case enabled
        case mode
        case indexStorePath
        case minConfidence
        case treatPublicAsRoot
        case treatObjcAsRoot
        case treatTestsAsRoot
        case treatSwiftUIViewsAsRoot
        case ignoreSwiftUIPropertyWrappers
        case ignorePreviewProviders
        case ignoreViewBody
        case ignorePublicAPI
        case sensibleDefaults
        case excludeImports
        case excludeDeinit
        case excludeEnumCases
        case excludeTestSuites
        case excludeNamePatterns
        case excludePaths
    }
}

// MARK: - DuplicatesConfiguration.CodingKeys

extension DuplicatesConfiguration {
    enum CodingKeys: String, CodingKey {
        case enabled
        case minTokens
        case minSimilarity
        case types
        case algorithm
        case ignoredPatterns
        case excludePaths
    }
}
