//  UnusedCodeFilter.swift
//  SwiftStaticAnalysis
//  MIT License

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

        // Compile custom path globs through the canonical `GlobMatcher`
        // translation and anchor the result so `String.contains(regex)` on
        // an anchored pattern behaves as a whole-match (the same anchored
        // semantics MCP `CodebaseContext.matchesGlobPattern` uses).
        compiledPathPatterns = CompiledPatterns(
            configuration.excludePathPatterns
                .filter { !Self.isCommonGlob($0) }
                .map { "^\(GlobMatcher.translate(pattern: $0))$" }
        )
        namePatterns = CompiledPatterns(configuration.excludeNamePatterns)
    }

    // MARK: Public

    /// Filter configuration.
    public let configuration: UnusedCodeFilterConfiguration

    // MARK: - Helpers

    /// Check if a name is a backticked identifier.
    public static func isBacktickedIdentifier(_ name: String) -> Bool {
        SwiftStaticAnalysisCore.isBacktickedIdentifier(name)
    }

    /// Check if a name looks like a test suite.
    public static func isTestSuiteName(_ name: String) -> Bool {
        name.hasSuffix("Tests") || name.hasSuffix("Test")
    }

    /// Check if a path matches a glob pattern.
    ///
    /// Uses hand-tuned fast paths for the three most common project-level
    /// globs (avoiding regex compilation altogether) and falls back to the
    /// canonical ``GlobMatcher`` for anything else. Both the CLI and the
    /// MCP `CodebaseContext` route through `GlobMatcher`'s anchored
    /// `wholeMatch` semantics.
    public static func matchesGlobPattern(_ path: String, pattern: String) -> Bool {
        switch pattern {
        case "**/Tests/**":
            return pathMatchesTestsGlob(path)
        case "**/*Tests.swift":
            return pathMatchesTestFileSuffixGlob(path)
        case "**/Fixtures/**":
            return pathMatchesFixturesGlob(path)
        default:
            return GlobMatcher.matches(path: path, pattern: pattern)
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

        // Underscore is Swift's "discard this value" identifier - never report as unused
        if name == "_" {
            return true
        }

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

        for pattern in configuration.excludePathPatterns {
            switch pattern {
            case "**/Tests/**":
                if pathMatchesTestsGlob(filePath) { return true }
            case "**/*Tests.swift":
                if pathMatchesTestFileSuffixGlob(filePath) { return true }
            case "**/Fixtures/**":
                if pathMatchesFixturesGlob(filePath) { return true }
            default:
                break
            }
        }

        if compiledPathPatterns.anyMatches(filePath) {
            return true
        }

        return namePatterns.anyMatches(name)
    }

    // MARK: Private

    /// Pre-compiled custom path patterns.
    private let compiledPathPatterns: CompiledPatterns

    /// Pre-compiled name patterns.
    private let namePatterns: CompiledPatterns

    private static func isCommonGlob(_ pattern: String) -> Bool {
        switch pattern {
        case "**/Tests/**", "**/*Tests.swift", "**/Fixtures/**":
            return true
        default:
            return false
        }
    }
}

// MARK: - Convenience Extensions

// swa:ignore-unused - Convenience extensions for API completeness
extension [UnusedCode] {
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
