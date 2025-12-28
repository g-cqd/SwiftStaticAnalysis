//
//  DiagnosticDeduplicator.swift
//  SwiftStaticAnalysis
//
//  Deduplication and merging of diagnostics.
//

import Foundation

// MARK: - Diagnostic Deduplicator

/// Deduplicates diagnostics to prevent duplicate warnings/errors.
public struct DiagnosticDeduplicator: Sendable {
    /// Configuration for deduplication.
    public let configuration: DeduplicationConfiguration

    public init(configuration: DeduplicationConfiguration = .default) {
        self.configuration = configuration
    }

    /// Deduplicate a list of diagnostics.
    ///
    /// - Parameter diagnostics: Diagnostics to deduplicate.
    /// - Returns: Deduplicated diagnostics.
    public func deduplicate(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        var seen = Set<String>()
        var result: [Diagnostic] = []

        for diagnostic in diagnostics {
            let key = deduplicationKey(for: diagnostic)

            if !seen.contains(key) {
                seen.insert(key)
                result.append(diagnostic)
            }
        }

        // Apply per-file limit if configured
        if let limit = configuration.maxDiagnosticsPerFile {
            result = applyPerFileLimit(result, limit: limit)
        }

        return result
    }

    /// Merge diagnostics from multiple sources.
    ///
    /// - Parameter sources: Multiple arrays of diagnostics.
    /// - Returns: Merged and deduplicated diagnostics.
    public func merge(_ sources: [[Diagnostic]]) -> [Diagnostic] {
        var all: [Diagnostic] = []

        for source in sources {
            all.append(contentsOf: source)
        }

        // Sort by file, line, column for consistent ordering
        all.sort { lhs, rhs in
            if lhs.file != rhs.file {
                return lhs.file < rhs.file
            }
            if lhs.line != rhs.line {
                return lhs.line < rhs.line
            }
            return lhs.column < rhs.column
        }

        return deduplicate(all)
    }

    /// Group related diagnostics.
    ///
    /// - Parameter diagnostics: Diagnostics to group.
    /// - Returns: Grouped diagnostics (primary with notes attached).
    public func groupRelated(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        guard configuration.groupRelatedDiagnostics else {
            return diagnostics
        }

        var result: [Diagnostic] = []
        var byLocation: [String: [Diagnostic]] = [:]

        // Group by file
        for diagnostic in diagnostics {
            byLocation[diagnostic.file, default: []].append(diagnostic)
        }

        // Process each file's diagnostics
        for (_, fileDiagnostics) in byLocation {
            // Sort by line
            let sorted = fileDiagnostics.sorted { $0.line < $1.line }

            // Group adjacent diagnostics
            var i = 0
            while i < sorted.count {
                var primary = sorted[i]
                var notes: [Diagnostic] = []

                // Look for related diagnostics (within 5 lines)
                var j = i + 1
                while j < sorted.count && sorted[j].line - primary.line <= 5 {
                    // Convert secondary to note if it's a lower severity
                    if sorted[j].severity.priority < primary.severity.priority {
                        let note = Diagnostic(
                            file: sorted[j].file,
                            line: sorted[j].line,
                            column: sorted[j].column,
                            severity: .note,
                            message: sorted[j].message,
                            category: sorted[j].category
                        )
                        notes.append(note)
                    } else {
                        break
                    }
                    j += 1
                }

                // Create grouped diagnostic
                if !notes.isEmpty {
                    primary = Diagnostic(
                        file: primary.file,
                        line: primary.line,
                        column: primary.column,
                        severity: primary.severity,
                        message: primary.message,
                        category: primary.category,
                        ruleID: primary.ruleID,
                        fixIt: primary.fixIt,
                        notes: primary.notes + notes
                    )
                    i = j
                } else {
                    i += 1
                }

                result.append(primary)
            }
        }

        return result
    }

    // MARK: - Private Helpers

    private func deduplicationKey(for diagnostic: Diagnostic) -> String {
        switch configuration.deduplicationLevel {
        case .exact:
            return diagnostic.uniqueKey
        case .location:
            return "\(diagnostic.file):\(diagnostic.line):\(diagnostic.column)"
        case .message:
            return "\(diagnostic.file):\(diagnostic.message.hashValue)"
        case .locationAndSeverity:
            return "\(diagnostic.file):\(diagnostic.line):\(diagnostic.column):\(diagnostic.severity.rawValue)"
        }
    }

    private func applyPerFileLimit(_ diagnostics: [Diagnostic], limit: Int) -> [Diagnostic] {
        var countByFile: [String: Int] = [:]
        var result: [Diagnostic] = []

        for diagnostic in diagnostics {
            let currentCount = countByFile[diagnostic.file, default: 0]

            if currentCount < limit {
                result.append(diagnostic)
                countByFile[diagnostic.file] = currentCount + 1
            } else if currentCount == limit {
                // Add a summary note
                let summary = Diagnostic(
                    file: diagnostic.file,
                    line: 1,
                    column: 1,
                    severity: .note,
                    message: "Additional diagnostics in this file were suppressed (limit: \(limit))",
                    category: .general
                )
                result.append(summary)
                countByFile[diagnostic.file] = currentCount + 1
            }
            // Skip additional diagnostics beyond limit + 1
        }

        return result
    }
}

// MARK: - Deduplication Configuration

/// Configuration for diagnostic deduplication.
public struct DeduplicationConfiguration: Sendable {
    /// Level of deduplication.
    public var deduplicationLevel: DeduplicationLevel

    /// Maximum diagnostics per file (nil for unlimited).
    public var maxDiagnosticsPerFile: Int?

    /// Whether to group related diagnostics.
    public var groupRelatedDiagnostics: Bool

    /// Whether to prefer higher severity when deduplicating.
    public var preferHigherSeverity: Bool

    public init(
        deduplicationLevel: DeduplicationLevel = .exact,
        maxDiagnosticsPerFile: Int? = nil,
        groupRelatedDiagnostics: Bool = true,
        preferHigherSeverity: Bool = true
    ) {
        self.deduplicationLevel = deduplicationLevel
        self.maxDiagnosticsPerFile = maxDiagnosticsPerFile
        self.groupRelatedDiagnostics = groupRelatedDiagnostics
        self.preferHigherSeverity = preferHigherSeverity
    }

    /// Default configuration.
    public static let `default` = DeduplicationConfiguration()

    /// Strict deduplication (exact matches only).
    public static let strict = DeduplicationConfiguration(
        deduplicationLevel: .exact,
        maxDiagnosticsPerFile: nil,
        groupRelatedDiagnostics: false
    )

    /// Lenient deduplication (dedupe by location only).
    public static let lenient = DeduplicationConfiguration(
        deduplicationLevel: .location,
        maxDiagnosticsPerFile: 50,
        groupRelatedDiagnostics: true
    )
}

// MARK: - Deduplication Level

/// Level of deduplication to apply.
public enum DeduplicationLevel: String, Sendable, Codable {
    /// Exact match (file, line, column, severity, message).
    case exact

    /// Match by location only (file, line, column).
    case location

    /// Match by file and message.
    case message

    /// Match by location and severity.
    case locationAndSeverity
}

// MARK: - Severity Priority

extension DiagnosticSeverity {
    /// Priority for comparing severities.
    var priority: Int {
        switch self {
        case .error: return 4
        case .warning: return 3
        case .note: return 2
        case .remark: return 1
        }
    }
}
