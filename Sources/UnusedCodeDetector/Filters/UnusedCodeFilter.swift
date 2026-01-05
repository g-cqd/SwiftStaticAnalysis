//  UnusedCodeFilter.swift
//  SwiftStaticAnalysis
//  MIT License

import RegexBuilder
import SwiftStaticAnalysisCore

// MARK: - Pre-compiled Glob Patterns

/// Pre-compiled regex for `**/Tests/**` glob pattern.
///
/// Matches any path containing the `/Tests/` directory.
private nonisolated(unsafe) let testsGlobRegex = Regex {
    ZeroOrMore(.any)
    "/Tests/"
    ZeroOrMore(.any)
}

/// Pre-compiled regex for `**/*Tests.swift` glob pattern.
///
/// Matches any path ending with a filename that ends in `Tests.swift`.
private nonisolated(unsafe) let testFileSuffixGlobRegex = Regex {
    ZeroOrMore(.any)
    OneOrMore {
        CharacterClass.anyOf("/").inverted
    }
    "Tests.swift"
    Anchor.endOfSubject
}

/// Pre-compiled regex for `**/Fixtures/**` glob pattern.
///
/// Matches any path containing the `/Fixtures/` directory.
private nonisolated(unsafe) let fixturesGlobRegex = Regex {
    ZeroOrMore(.any)
    "/Fixtures/"
    ZeroOrMore(.any)
}

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
    ///
    /// Uses pre-compiled patterns for common globs, falling back to
    /// dynamic compilation for custom patterns.
    public static func matchesGlobPattern(_ path: String, pattern: String) -> Bool {
        // Try pre-compiled patterns first for common globs
        switch pattern {
        case "**/Tests/**":
            return path.contains(testsGlobRegex)
        case "**/*Tests.swift":
            return path.contains(testFileSuffixGlobRegex)
        case "**/Fixtures/**":
            return path.contains(fixturesGlobRegex)
        default:
            // Fall back to dynamic compilation
            let regexPattern = globToRegexPattern(pattern)
            guard let regex = try? Regex(regexPattern) else {
                return false
            }
            return path.contains(regex)
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

        // Check path patterns using pre-compiled where available
        for (index, pattern) in configuration.excludePathPatterns.enumerated() {
            // Use pre-compiled patterns for common globs
            switch pattern {
            case "**/Tests/**":
                if filePath.contains(testsGlobRegex) { return true }
            case "**/*Tests.swift":
                if filePath.contains(testFileSuffixGlobRegex) { return true }
            case "**/Fixtures/**":
                if filePath.contains(fixturesGlobRegex) { return true }
            default:
                // Fall back to compiled pattern string
                if index < compiledPathPatterns.count,
                    let regex = try? Regex(compiledPathPatterns[index]),
                    filePath.contains(regex)
                {
                    return true
                }
            }
        }

        // Check name patterns
        for pattern in namePatterns {
            if let regex = try? Regex(pattern),
                name.contains(regex)
            {
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
    ///
    /// Properly escapes all regex metacharacters to prevent regex injection,
    /// then converts glob wildcards to their regex equivalents.
    private static func globToRegexPattern(_ pattern: String) -> String {
        // Placeholder for glob wildcards to preserve them during escaping
        let doubleStarPlaceholder = "\u{0000}DOUBLESTAR\u{0000}"
        let singleStarPlaceholder = "\u{0000}SINGLESTAR\u{0000}"
        let questionPlaceholder = "\u{0000}QUESTION\u{0000}"

        var result =
            pattern
            // First, replace glob wildcards with placeholders
            .replacingOccurrences(of: "**", with: doubleStarPlaceholder)
            .replacingOccurrences(of: "*", with: singleStarPlaceholder)
            .replacingOccurrences(of: "?", with: questionPlaceholder)

        // Escape all regex metacharacters (order matters - backslash first)
        let metacharacters: [(String, String)] = [
            ("\\", "\\\\"),  // Backslash must be escaped first
            (".", "\\."),
            ("^", "\\^"),
            ("$", "\\$"),
            ("+", "\\+"),
            ("[", "\\["),
            ("]", "\\]"),
            ("(", "\\("),
            (")", "\\)"),
            ("{", "\\{"),
            ("}", "\\}"),
            ("|", "\\|"),
        ]

        for (char, escaped) in metacharacters {
            result = result.replacingOccurrences(of: char, with: escaped)
        }

        // Convert glob placeholders to regex equivalents
        return
            result
            .replacingOccurrences(of: doubleStarPlaceholder, with: ".*")
            .replacingOccurrences(of: singleStarPlaceholder, with: "[^/]*")
            .replacingOccurrences(of: questionPlaceholder, with: ".")
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
