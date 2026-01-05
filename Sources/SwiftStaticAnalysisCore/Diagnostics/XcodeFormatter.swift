//  XcodeFormatter.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - XcodeFormatter

/// Formats diagnostics for Xcode integration.
public struct XcodeFormatter: Sendable {
    // MARK: Lifecycle

    public init(configuration: XcodeFormatterConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: Public

    /// Configuration for formatting.
    public let configuration: XcodeFormatterConfiguration

    /// Format diagnostics for Xcode output.
    ///
    /// - Parameter diagnostics: Diagnostics to format.
    /// - Returns: Formatted string for Xcode.
    public func format(_ diagnostics: [Diagnostic]) -> String {
        var lines: [String] = []

        for diagnostic in diagnostics {
            lines.append(formatDiagnostic(diagnostic))

            // Add notes
            for note in diagnostic.notes {
                lines.append(formatDiagnostic(note))
            }

            // Add fix-it if present and enabled
            if configuration.includeFixIts, let fixIt = diagnostic.fixIt {
                lines.append(formatFixIt(fixIt, at: diagnostic))
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Private

    /// Format a single diagnostic.
    private func formatDiagnostic(_ diagnostic: Diagnostic) -> String {
        var message = diagnostic.message

        // Add rule ID if configured
        if configuration.includeRuleID, let ruleID = diagnostic.ruleID {
            message = "[\(ruleID)] \(message)"
        }

        // Add category if configured
        if configuration.includeCategory {
            message = "(\(diagnostic.category.rawValue)) \(message)"
        }

        return
            "\(diagnostic.file):\(diagnostic.line):\(diagnostic.column): \(diagnostic.severity.xcodeString): \(message)"
    }

    /// Format a fix-it suggestion.
    private func formatFixIt(_ fixIt: FixIt, at diagnostic: Diagnostic) -> String {
        "\(diagnostic.file):\(diagnostic.line):\(diagnostic.column): note: fix-it: \(fixIt.description)"
    }
}

// MARK: - XcodeFormatterConfiguration

/// Configuration for Xcode formatter.
public struct XcodeFormatterConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        includeRuleID: Bool = false,
        includeCategory: Bool = false,
        includeFixIts: Bool = true,
        useRelativePaths: Bool = false,
        basePath: String? = nil,
    ) {
        self.includeRuleID = includeRuleID
        self.includeCategory = includeCategory
        self.includeFixIts = includeFixIts
        self.useRelativePaths = useRelativePaths
        self.basePath = basePath
    }

    // MARK: Public

    /// Default configuration.
    public static let `default` = Self()

    /// Verbose configuration (includes all metadata).
    public static let verbose = Self(
        includeRuleID: true,
        includeCategory: true,
        includeFixIts: true,
    )

    /// Minimal configuration.
    public static let minimal = Self(
        includeRuleID: false,
        includeCategory: false,
        includeFixIts: false,
    )

    /// Include rule ID in output.
    public var includeRuleID: Bool

    /// Include category in output.
    public var includeCategory: Bool

    /// Include fix-it suggestions.
    public var includeFixIts: Bool

    /// Use relative paths.
    public var useRelativePaths: Bool

    /// Base path for relative paths.
    public var basePath: String?
}

// MARK: - Diagnostic Conversion

// swa:ignore-unused - Factory methods for API completeness and future Xcode integration
extension Diagnostic {
    /// Create a diagnostic from an unused code finding.
    ///
    /// This factory method converts an unused code detection result into
    /// an Xcode-compatible diagnostic format.
    ///
    /// - Parameters:
    ///   - declaration: The unused declaration.
    ///   - reason: Why the declaration is considered unused.
    ///   - suggestion: Action suggestion for the user.
    ///   - severity: Diagnostic severity level.
    /// - Returns: A formatted diagnostic.
    public static func fromUnusedCode(
        declaration: Declaration,
        reason: String,
        suggestion: String,
        severity: DiagnosticSeverity = .warning,
    ) -> Diagnostic {
        Diagnostic(
            file: declaration.location.file,
            line: declaration.location.line,
            column: declaration.location.column,
            severity: severity,
            message: "\(suggestion) (\(reason))",
            category: .unusedCode,
            ruleID: "unused-\(declaration.kind.rawValue)",
        )
    }

    /// Create diagnostics from a clone group.
    ///
    /// This factory method converts a clone detection result into
    /// Xcode-compatible diagnostics with notes linking related occurrences.
    ///
    /// - Parameters:
    ///   - clones: Array of clone locations (file, startLine, endLine).
    ///   - cloneType: Type of clone (exact, near, semantic).
    ///   - severity: Diagnostic severity level.
    /// - Returns: Array of formatted diagnostics.
    public static func fromCloneGroup(
        clones: [(file: String, startLine: Int, endLine: Int)],
        cloneType: String,
        severity: DiagnosticSeverity = .warning,
    ) -> [Diagnostic] {
        guard let first = clones.first else { return [] }

        // Primary diagnostic at first occurrence
        let primary = Diagnostic(
            file: first.file,
            line: first.startLine,
            column: 1,
            severity: severity,
            message: "Duplicate code detected (\(cloneType) clone, \(clones.count) occurrences)",
            category: .duplication,
            ruleID: "duplicate-\(cloneType)",
        )

        // Add notes for other occurrences
        var notes: [Diagnostic] = []
        for clone in clones.dropFirst() {
            let note = Diagnostic(
                file: clone.file,
                line: clone.startLine,
                column: 1,
                severity: .note,
                message: "Also appears here (lines \(clone.startLine)-\(clone.endLine))",
                category: .duplication,
            )
            notes.append(note)
        }

        let primaryWithNotes = primary.replacingNotes(notes)
        return [primaryWithNotes]
    }
}
