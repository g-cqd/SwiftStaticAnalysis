//  CompactTextFormatter.swift
//  SwiftStaticAnalysis
//  MIT License

import DuplicationDetector
import Foundation
import UnusedCodeDetector

// MARK: - CompactTextFormatter

/// Shared compact text formatters for human and LLM-readable output.
public enum CompactTextFormatter {
    /// Format unused code results in compact text.
    ///
    /// - Parameters:
    ///   - unused: Unused code findings.
    ///   - rootPath: Optional root path used to shorten file paths.
    ///   - includeHeader: Whether to include the leading summary header.
    /// - Returns: Compact formatted output.
    public static func formatUnused(
        _ unused: [UnusedCode],
        rootPath: String? = nil,
        includeHeader: Bool = true
    ) -> String {
        if unused.isEmpty {
            return includeHeader ? "UNUSED 0 items\n(none)" : "(none)"
        }

        let byFile = Dictionary(grouping: unused) { $0.declaration.location.file }
        let sections = byFile.keys.sorted().compactMap { file -> String? in
            guard let items = byFile[file] else { return nil }
            let sortedItems = items.sorted { $0.declaration.location.line < $1.declaration.location.line }

            var section = displayPath(for: file, rootPath: rootPath)
            for item in sortedItems {
                let declaration = item.declaration
                let confidence = String(item.confidence.rawValue.prefix(1)).uppercased()
                section +=
                    "\n  \(declaration.location.line) \(declaration.kind.rawValue) \(declaration.name) [\(confidence)] \(shortReason(item.reason))"
            }

            return section
        }

        let body = sections.joined(separator: "\n\n")
        if includeHeader {
            return "UNUSED \(unused.count) items\n\n\(body)"
        }

        return "\n\(body)"
    }

    /// Format clone groups in compact text.
    ///
    /// - Parameters:
    ///   - clones: Clone groups to format.
    ///   - rootPath: Optional root path used to shorten file paths.
    ///   - includeHeader: Whether to include the leading summary header.
    /// - Returns: Compact formatted output.
    public static func formatClones(
        _ clones: [CloneGroup],
        rootPath: String? = nil,
        includeHeader: Bool = true
    ) -> String {
        if clones.isEmpty {
            return includeHeader ? "CLONES 0 groups\n(none)" : "(none)"
        }

        let byType = Dictionary(grouping: clones) { $0.type }
        let sections = [CloneType.exact, .near, .semantic].compactMap { type -> String? in
            guard let groups = byType[type], !groups.isEmpty else { return nil }

            let totalLines = groups.reduce(0) { $0 + $1.duplicatedLines }
            var section = "\(type.rawValue) \(groups.count) groups \(totalLines) duplicated lines"

            for (index, group) in groups.enumerated() {
                let similaritySuffix = group.similarity < 1.0 ? " \(Int(group.similarity * 100))%" : ""
                let linesPerOccurrence = group.duplicatedLines / max(1, group.occurrences - 1)
                section += "\n  [\(index + 1)]\(similaritySuffix) \(group.occurrences)x \(linesPerOccurrence)L"

                let byFile = Dictionary(grouping: group.clones) { $0.file }
                for (file, fileClones) in byFile.sorted(by: { $0.key < $1.key }) {
                    let ranges = fileClones.map { "\($0.startLine)-\($0.endLine)" }.joined(separator: " ")
                    section += "\n    \(displayPath(for: file, rootPath: rootPath)): \(ranges)"
                }
            }

            return section
        }

        let body = sections.joined(separator: "\n\n")
        if includeHeader {
            return "CLONES \(clones.count) groups\n\n\(body)"
        }

        return "\n\(body)"
    }

    // MARK: Private

    private static func displayPath(for path: String, rootPath: String?) -> String {
        guard let rootPath, path.hasPrefix(rootPath) else {
            return path
        }

        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func shortReason(_ reason: UnusedReason) -> String {
        switch reason {
        case .neverReferenced: return "unused"
        case .onlyAssigned: return "written-only"
        case .onlySelfReferenced: return "self-ref"
        case .importNotUsed: return "unused-import"
        case .parameterUnused: return "unused-param"
        case .deadBranch: return "dead-branch"
        }
    }
}
