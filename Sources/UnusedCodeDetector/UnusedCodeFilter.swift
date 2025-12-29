//
//  UnusedCodeFilter.swift
//  SwiftStaticAnalysis
//
//  Filters for excluding false positives from unused code detection results.
//

import Foundation
import SwiftStaticAnalysisCore

// MARK: - Filter Configuration

/// Configuration for filtering unused code results.
public struct UnusedCodeFilterConfiguration: Sendable {
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

    public init(
        excludeImports: Bool = false,
        excludeDeinit: Bool = false,
        excludeBacktickedEnumCases: Bool = false,
        excludeTestSuites: Bool = false,
        excludePathPatterns: [String] = [],
        excludeNamePatterns: [String] = [],
        respectIgnoreDirectives: Bool = true
    ) {
        self.excludeImports = excludeImports
        self.excludeDeinit = excludeDeinit
        self.excludeBacktickedEnumCases = excludeBacktickedEnumCases
        self.excludeTestSuites = excludeTestSuites
        self.excludePathPatterns = excludePathPatterns
        self.excludeNamePatterns = excludeNamePatterns
        self.respectIgnoreDirectives = respectIgnoreDirectives
    }

    /// No filtering.
    public static let none = UnusedCodeFilterConfiguration(respectIgnoreDirectives: false)

    /// Sensible defaults that exclude common false positives.
    public static let sensibleDefaults = UnusedCodeFilterConfiguration(
        excludeImports: true,
        excludeDeinit: true,
        excludeBacktickedEnumCases: true,
        excludeTestSuites: true,
        respectIgnoreDirectives: true
    )

    /// Strict filtering for production code only.
    public static func production(excludeTestPaths: Bool = true) -> UnusedCodeFilterConfiguration {
        var config = sensibleDefaults
        if excludeTestPaths {
            config.excludePathPatterns = ["**/Tests/**", "**/*Tests.swift", "**/Fixtures/**"]
        }
        return config
    }
}

// MARK: - Unused Code Filter

/// Filters unused code results to exclude false positives.
public struct UnusedCodeFilter: Sendable {
    /// Filter configuration.
    public let configuration: UnusedCodeFilterConfiguration

    /// Compiled path pattern regexes.
    private let pathRegexes: [NSRegularExpression]

    /// Compiled name pattern regexes.
    private let nameRegexes: [NSRegularExpression]

    public init(configuration: UnusedCodeFilterConfiguration = .none) {
        self.configuration = configuration

        // Compile path patterns to regexes
        self.pathRegexes = configuration.excludePathPatterns.compactMap { pattern in
            Self.compileGlobPattern(pattern)
        }

        // Compile name patterns to regexes
        self.nameRegexes = configuration.excludeNamePatterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [])
        }
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
        if configuration.respectIgnoreDirectives && item.declaration.shouldIgnoreUnused {
            return true
        }

        // Check imports
        if configuration.excludeImports && item.declaration.kind == .import {
            return true
        }

        // Check deinit
        if configuration.excludeDeinit && name == "deinit" {
            return true
        }

        // Check backticked enum cases
        if configuration.excludeBacktickedEnumCases && Self.isBacktickedIdentifier(name) {
            return true
        }

        // Check test suites
        if configuration.excludeTestSuites && Self.isTestSuiteName(name) {
            return true
        }

        // Check path patterns
        for regex in pathRegexes {
            let range = NSRange(filePath.startIndex..., in: filePath)
            if regex.firstMatch(in: filePath, options: [], range: range) != nil {
                return true
            }
        }

        // Check name patterns
        for regex in nameRegexes {
            let range = NSRange(name.startIndex..., in: name)
            if regex.firstMatch(in: name, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }

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
        guard let regex = compileGlobPattern(pattern) else {
            return false
        }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    /// Compile a glob pattern to a regex.
    private static func compileGlobPattern(_ pattern: String) -> NSRegularExpression? {
        let regexPattern = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "**", with: "<<<DOUBLESTAR>>>")
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "<<<DOUBLESTAR>>>", with: ".*")
            .replacingOccurrences(of: "?", with: ".")

        return try? NSRegularExpression(pattern: regexPattern, options: [])
    }
}

// MARK: - Convenience Extensions

extension Array where Element == UnusedCode {
    /// Filter results using the specified configuration.
    public func filtered(with configuration: UnusedCodeFilterConfiguration) -> [UnusedCode] {
        let filter = UnusedCodeFilter(configuration: configuration)
        return filter.filter(self)
    }

    /// Filter results with sensible defaults.
    public func filteredWithSensibleDefaults() -> [UnusedCode] {
        filtered(with: .sensibleDefaults)
    }
}
