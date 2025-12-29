//
//  XcodeFormatter.swift
//  SwiftStaticAnalysis
//
//  Format diagnostics for Xcode integration.
//

import Foundation

// MARK: - Xcode Formatter

/// Formats diagnostics for Xcode integration.
public struct XcodeFormatter: Sendable {
    /// Configuration for formatting.
    public let configuration: XcodeFormatterConfiguration

    public init(configuration: XcodeFormatterConfiguration = .default) {
        self.configuration = configuration
    }

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

        return "\(diagnostic.file):\(diagnostic.line):\(diagnostic.column): \(diagnostic.severity.xcodeString): \(message)"
    }

    /// Format a fix-it suggestion.
    private func formatFixIt(_ fixIt: FixIt, at diagnostic: Diagnostic) -> String {
        "\(diagnostic.file):\(diagnostic.line):\(diagnostic.column): note: fix-it: \(fixIt.description)"
    }
}

// MARK: - Xcode Formatter Configuration

/// Configuration for Xcode formatter.
public struct XcodeFormatterConfiguration: Sendable {
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

    public init(
        includeRuleID: Bool = false,
        includeCategory: Bool = false,
        includeFixIts: Bool = true,
        useRelativePaths: Bool = false,
        basePath: String? = nil
    ) {
        self.includeRuleID = includeRuleID
        self.includeCategory = includeCategory
        self.includeFixIts = includeFixIts
        self.useRelativePaths = useRelativePaths
        self.basePath = basePath
    }

    /// Default configuration.
    public static let `default` = XcodeFormatterConfiguration()

    /// Verbose configuration (includes all metadata).
    public static let verbose = XcodeFormatterConfiguration(
        includeRuleID: true,
        includeCategory: true,
        includeFixIts: true
    )

    /// Minimal configuration.
    public static let minimal = XcodeFormatterConfiguration(
        includeRuleID: false,
        includeCategory: false,
        includeFixIts: false
    )
}

// MARK: - Diagnostic Conversion

extension Diagnostic {
    /// Create a diagnostic from an unused code finding.
    public static func fromUnusedCode(
        declaration: Declaration,
        reason: String,
        suggestion: String,
        severity: DiagnosticSeverity = .warning
    ) -> Diagnostic {
        Diagnostic(
            file: declaration.location.file,
            line: declaration.location.line,
            column: declaration.location.column,
            severity: severity,
            message: suggestion,
            category: .unusedCode,
            ruleID: "unused-\(declaration.kind.rawValue)"
        )
    }

    /// Create a diagnostic from a clone group.
    public static func fromCloneGroup(
        clones: [(file: String, startLine: Int, endLine: Int)],
        cloneType: String,
        severity: DiagnosticSeverity = .warning
    ) -> [Diagnostic] {
        guard let first = clones.first else { return [] }

        var diagnostics: [Diagnostic] = []

        // Primary diagnostic at first occurrence
        let primary = Diagnostic(
            file: first.file,
            line: first.startLine,
            column: 1,
            severity: severity,
            message: "Duplicate code detected (\(cloneType) clone, \(clones.count) occurrences)",
            category: .duplication,
            ruleID: "duplicate-\(cloneType)"
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
                category: .duplication
            )
            notes.append(note)
        }

        let primaryWithNotes = primary.replacingNotes(notes)

        diagnostics.append(primaryWithNotes)
        return diagnostics
    }
}
