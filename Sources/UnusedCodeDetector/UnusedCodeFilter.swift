//
//  UnusedCodeFilter.swift
//  SwiftStaticAnalysis
//
//  Filters for excluding false positives from unused code detection results.
//

import RegexBuilder
import SwiftStaticAnalysisCore

// MARK: - UnusedCodeFilterConfiguration

/// Configuration for filtering unused code results.
public struct UnusedCodeFilterConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        excludeImports: Bool = false,
        excludeDeinit: Bool = false,
        excludeBacktickedEnumCases: Bool = false,
        excludeTestSuites: Bool = false,
        excludePathPatterns: [String] = [],
        excludeNamePatterns: [String] = [],
        respectIgnoreDirectives: Bool = true,
    ) {
        self.excludeImports = excludeImports
        self.excludeDeinit = excludeDeinit
        self.excludeBacktickedEnumCases = excludeBacktickedEnumCases
        self.excludeTestSuites = excludeTestSuites
        self.excludePathPatterns = excludePathPatterns
        self.excludeNamePatterns = excludeNamePatterns
        self.respectIgnoreDirectives = respectIgnoreDirectives
    }

    // MARK: Public

    /// No filtering.
    public static let none = Self(respectIgnoreDirectives: false)

    /// Sensible defaults that exclude common false positives.
    public static let sensibleDefaults = Self(
        excludeImports: true,
        excludeDeinit: true,
        excludeBacktickedEnumCases: true,
        excludeTestSuites: true,
        respectIgnoreDirectives: true,
    )

    /// Exclude import statements.
    public var excludeImports: Bool

    /// Exclude deinit methods.
    public var excludeDeinit: Bool

    /// Exclude backticked enum cases (Swift keywords used as identifiers).
    public var excludeBacktickedEnumCases: Bool

    /// Exclude test suite declarations (names ending with "Tests").
    public var excludeTestSuites: Bool

    /// Path patterns to exclude (glob syntax).
    public var excludePathPatterns: [String]

    /// Name patterns to exclude (regex).
    public var excludeNamePatterns: [String]

    /// Respect `// swa:ignore` comment directives.
    public var respectIgnoreDirectives: Bool

    /// Strict filtering for production code only.
    public static func production(excludeTestPaths: Bool = true) -> Self {
        var config = sensibleDefaults
        if excludeTestPaths {
            config.excludePathPatterns = ["**/Tests/**", "**/*Tests.swift", "**/Fixtures/**"]
        }
        return config
    }
}

// MARK: - UnusedCodeFilter

/// Filters unused code results to exclude false positives.
public struct UnusedCodeFilter: Sendable {
    // MARK: Lifecycle

    public init(configuration: UnusedCodeFilterConfiguration = .none) {
        self.configuration = configuration

        // Pre-compile glob patterns to regex pattern strings
        compiledPathPatterns = configuration.excludePathPatterns.compactMap { pattern in
            Self.globToRegexPattern(pattern)
        }

        // Store name patterns for on-demand compilation
        namePatterns = configuration.excludeNamePatterns
    }

    // MARK: Public

    /// Filter configuration.
    public let configuration: UnusedCodeFilterConfiguration

    // MARK: - Helpers

    /// Check if a name is a backticked identifier.
    public static func isBacktickedIdentifier(_ name: String) -> Bool {
        name.hasPrefix("`") && name.hasSuffix("`")
    }

    /// Check if a name looks like a test suite.
    public static func isTestSuiteName(_ name: String) -> Bool {
        name.hasSuffix("Tests") || name.hasSuffix("Test")
    }

    /// Check if a path matches a glob pattern.
    public static func matchesGlobPattern(_ path: String, pattern: String) -> Bool {
        let regexPattern = globToRegexPattern(pattern)
        guard let regex = try? Regex(regexPattern) else {
            return false
        }
        return path.contains(regex)
    }

    // MARK: - Filtering

    /// Filter unused code results.
    ///
    /// - Parameter results: The unused code results to filter.
    /// - Returns: Filtered results with false positives removed.
    public func filter(_ results: [UnusedCode]) -> [UnusedCode] {
        results.filter { !shouldExclude($0) }
    }

    /// Check if a result should be excluded.
    ///
    /// - Parameter item: The unused code item to check.
    /// - Returns: True if the item should be excluded.
    public func shouldExclude(_ item: UnusedCode) -> Bool {
        let name = item.declaration.name
        let filePath = item.declaration.location.file

        // Check ignore directives first (// swa:ignore comments)
        if configuration.respectIgnoreDirectives, item.declaration.shouldIgnoreUnused {
            return true
        }

        // Check imports
        if configuration.excludeImports, item.declaration.kind == .import {
            return true
        }

        // Check deinit
        if configuration.excludeDeinit, name == "deinit" {
            return true
        }

        // Check backticked enum cases
        if configuration.excludeBacktickedEnumCases, Self.isBacktickedIdentifier(name) {
            return true
        }

        // Check test suites
        if configuration.excludeTestSuites, Self.isTestSuiteName(name) {
            return true
        }

        // Check path patterns
        for pattern in compiledPathPatterns {
            if let regex = try? Regex(pattern),
               filePath.contains(regex) {
                return true
            }
        }

        // Check name patterns
        for pattern in namePatterns {
            if let regex = try? Regex(pattern),
               name.contains(regex) {
                return true
            }
        }

        return false
    }

    // MARK: Private

    /// Pre-compiled glob-to-regex pattern strings (Sendable).
    private let compiledPathPatterns: [String]

    /// Name pattern strings for on-demand compilation (Sendable).
    private let namePatterns: [String]

    /// Convert a glob pattern to a regex pattern string.
    private static func globToRegexPattern(_ pattern: String) -> String {
        pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "**", with: "<<<DOUBLESTAR>>>")
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "<<<DOUBLESTAR>>>", with: ".*")
            .replacingOccurrences(of: "?", with: ".")
    }
}

// MARK: - Convenience Extensions

// swa:ignore-unused - Convenience extensions for API completeness
public extension [UnusedCode] {
    /// Filter results using the specified configuration.
    func filtered(with configuration: UnusedCodeFilterConfiguration) -> [UnusedCode] {
        let filter = UnusedCodeFilter(configuration: configuration)
        return filter.filter(self)
    }

    /// Filter results with sensible defaults.
    func filteredWithSensibleDefaults() -> [UnusedCode] {
        filtered(with: .sensibleDefaults)
    }
}
