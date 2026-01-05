//  ConfigurationLoader.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - ConfigurationLoader

/// Loads and parses `.swa.json` configuration files.
///
/// The loader searches for configuration files in the following order:
/// 1. `.swa.json` (hidden file, recommended)
/// 2. `swa.json` (visible file)
///
/// Usage:
/// ```swift
/// let loader = ConfigurationLoader()
/// if let config = try loader.load(from: projectDirectory) {
///     // Use configuration
/// }
/// ```
public struct ConfigurationLoader: Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// Standard configuration file names to search for.
    public static let configFileNames = [".swa.json", "swa.json"]

    /// Load configuration from a directory.
    ///
    /// - Parameter directory: The directory to search for configuration files.
    /// - Returns: The parsed configuration, or `nil` if no config file exists.
    /// - Throws: `ConfigurationError` if the file exists but cannot be parsed.
    public func load(from directory: URL) throws -> SWAConfiguration? {
        guard let configPath = findConfigFile(in: directory) else {
            return nil
        }
        return try loadFromFile(configPath)
    }

    /// Load configuration from a specific file path.
    ///
    /// - Parameter filePath: The path to the configuration file.
    /// - Returns: The parsed configuration.
    /// - Throws: `ConfigurationError` if the file cannot be read or parsed.
    public func loadFromFile(_ filePath: URL) throws -> SWAConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: filePath)
        } catch {
            throw ConfigurationError.fileReadError(path: filePath.path, underlying: error)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(SWAConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.parseError(path: filePath.path, underlying: error)
        }
    }

    /// Find the configuration file in a directory.
    ///
    /// Searches for standard configuration file names in order.
    ///
    /// - Parameter directory: The directory to search.
    /// - Returns: The URL of the first found config file, or `nil` if none exists.
    public func findConfigFile(in directory: URL) -> URL? {
        for name in Self.configFileNames {
            let path = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        return nil
    }
}

// MARK: - ConfigurationError

/// Errors that can occur when loading configuration.
public enum ConfigurationError: Error, CustomStringConvertible, Sendable {
    /// The configuration file could not be read.
    case fileReadError(path: String, underlying: Error)

    /// The configuration file could not be parsed.
    case parseError(path: String, underlying: Error)

    /// The configuration version is not supported.
    case unsupportedVersion(version: Int, path: String)

    // MARK: Public

    public var description: String {
        switch self {
        case .fileReadError(let path, let underlying):
            "Failed to read configuration file at \(path): \(underlying.localizedDescription)"

        case .parseError(let path, let underlying):
            "Failed to parse configuration file at \(path): \(underlying.localizedDescription)"

        case .unsupportedVersion(let version, let path):
            "Unsupported configuration version \(version) in \(path). Supported versions: 1"
        }
    }
}

// MARK: - Configuration Merging

extension SWAConfiguration {
    /// Merge this configuration with CLI-provided values.
    ///
    /// CLI values take precedence over configuration file values.
    /// Configuration file values take precedence over defaults.
    ///
    /// - Parameter cli: CLI-provided configuration values.
    /// - Returns: A new configuration with merged values.
    public func merging(with cli: SWAConfiguration) -> SWAConfiguration {
        SWAConfiguration(
            version: cli.version ?? version,
            format: cli.format ?? format,
            excludePaths: mergeArrays(base: excludePaths, override: cli.excludePaths),
            unused: mergeUnused(base: unused, override: cli.unused),
            duplicates: mergeDuplicates(base: duplicates, override: cli.duplicates),
        )
    }

    // MARK: Private

    private func mergeArrays(base: [String]?, override: [String]?) -> [String]? {
        // If override is explicitly provided, use it; otherwise use base
        if let override, !override.isEmpty {
            return override
        }
        return base
    }

    private func mergeUnused(
        base: UnusedConfiguration?,
        override: UnusedConfiguration?,
    ) -> UnusedConfiguration? {
        guard let base else { return override }
        guard let override else { return base }

        return UnusedConfiguration(
            enabled: override.enabled ?? base.enabled,
            mode: override.mode ?? base.mode,
            indexStorePath: override.indexStorePath ?? base.indexStorePath,
            minConfidence: override.minConfidence ?? base.minConfidence,
            treatPublicAsRoot: override.treatPublicAsRoot ?? base.treatPublicAsRoot,
            treatObjcAsRoot: override.treatObjcAsRoot ?? base.treatObjcAsRoot,
            treatTestsAsRoot: override.treatTestsAsRoot ?? base.treatTestsAsRoot,
            treatSwiftUIViewsAsRoot: override.treatSwiftUIViewsAsRoot ?? base.treatSwiftUIViewsAsRoot,
            ignoreSwiftUIPropertyWrappers: override.ignoreSwiftUIPropertyWrappers ?? base.ignoreSwiftUIPropertyWrappers,
            ignorePreviewProviders: override.ignorePreviewProviders ?? base.ignorePreviewProviders,
            ignoreViewBody: override.ignoreViewBody ?? base.ignoreViewBody,
            ignorePublicAPI: override.ignorePublicAPI ?? base.ignorePublicAPI,
            sensibleDefaults: override.sensibleDefaults ?? base.sensibleDefaults,
            excludeImports: override.excludeImports ?? base.excludeImports,
            excludeDeinit: override.excludeDeinit ?? base.excludeDeinit,
            excludeEnumCases: override.excludeEnumCases ?? base.excludeEnumCases,
            excludeTestSuites: override.excludeTestSuites ?? base.excludeTestSuites,
            excludeNamePatterns: mergeArrays(
                base: base.excludeNamePatterns,
                override: override.excludeNamePatterns,
            ),
            excludePaths: mergeArrays(base: base.excludePaths, override: override.excludePaths),
        )
    }

    private func mergeDuplicates(
        base: DuplicatesConfiguration?,
        override: DuplicatesConfiguration?,
    ) -> DuplicatesConfiguration? {
        guard let base else { return override }
        guard let override else { return base }

        return DuplicatesConfiguration(
            enabled: override.enabled ?? base.enabled,
            minTokens: override.minTokens ?? base.minTokens,
            minSimilarity: override.minSimilarity ?? base.minSimilarity,
            types: mergeArrays(base: base.types, override: override.types),
            algorithm: override.algorithm ?? base.algorithm,
            ignoredPatterns: mergeArrays(base: base.ignoredPatterns, override: override.ignoredPatterns),
            excludePaths: mergeArrays(base: base.excludePaths, override: override.excludePaths),
        )
    }
}
