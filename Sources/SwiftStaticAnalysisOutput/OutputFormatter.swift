//  OutputFormatter.swift
//  SwiftStaticAnalysis
//  MIT License

import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore
import SymbolLookup
import UnusedCodeDetector

// MARK: - CombinedReport

/// Canonical JSON shape for the `swa analyze` combined report. Reused by
/// the CLI, the MCP server, and any consumer that wants to render both
/// duplicate and unused findings in a single payload.
public struct CombinedReport: Codable, Sendable {
    public let clones: [CloneGroup]
    public let unused: [UnusedCode]

    public init(clones: [CloneGroup], unused: [UnusedCode]) {
        self.clones = clones
        self.unused = unused
    }
}

// MARK: - OutputFormatter

/// Shared formatting utilities for every consumer that prints analyzer
/// results — CLI subcommands, MCP responses, LSP integrations.
///
/// Promoted out of `Sources/swa/SWA.swift` (where it was unreachable
/// from any library) into the shared output module so all consumers
/// route through one renderer.
///
/// Text output is optimized for both human and LLM consumption:
/// - Grouped by file to reduce path repetition
/// - Positional semantics instead of repeated key labels
/// - Minimal markup (indentation over brackets)
/// - Stats/summary at top for quick understanding
public enum OutputFormatter {
    // MARK: - Text Format (Compact, LLM-optimized)

    /// Print clone groups in compact text format.
    public static func printCloneGroupsText(_ clones: [CloneGroup], header: String? = nil) {
        if let header { print(header) }
        print(CompactTextFormatter.formatClones(clones, includeHeader: false))
    }

    /// Print clone groups in Xcode-compatible warning format.
    public static func printCloneGroupsXcode(_ clones: [CloneGroup]) {
        for group in clones {
            for clone in group.clones {
                print(
                    "\(clone.file):\(clone.startLine): warning: Duplicate code detected (\(group.type.rawValue) clone, \(group.occurrences) occurrences)",
                )
            }
        }
    }

    /// Print unused code items in compact text format.
    public static func printUnusedText(_ unused: [UnusedCode]) {
        print(CompactTextFormatter.formatUnused(unused, includeHeader: false))
    }

    /// Print unused code items in Xcode-compatible warning format.
    public static func printUnusedXcode(_ unused: [UnusedCode]) {
        for item in unused {
            let loc = item.declaration.location
            print("\(loc.file):\(loc.line):\(loc.column): warning: \(item.suggestion)")
        }
    }

    /// Encode and print as JSON.
    public static func printJSON(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value),
            let json = String(data: data, encoding: .utf8)
        {
            print(json)
        }
    }

    // MARK: - Symbol Output (Compact)

    /// Print symbol matches in compact text format.
    public static func printSymbolsText(
        _ matches: [SymbolMatch],
        contexts: [SymbolMatch: SymbolContext] = [:]
    ) {
        if matches.isEmpty {
            print("(none)")
            return
        }

        let byFile = Dictionary(grouping: matches) { $0.file }
        let sortedFiles = byFile.keys.sorted()

        for file in sortedFiles {
            guard let fileMatches = byFile[file] else { continue }
            let sorted = fileMatches.sorted { $0.line < $1.line }

            print("\n\(file)")
            for match in sorted {
                var line = "  \(match.line):\(match.column) \(match.kind.rawValue) \(match.name)"
                if !match.genericParameters.isEmpty {
                    line += "<\(match.genericParameters.joined(separator: ","))>"
                }
                line += " \(match.accessLevel.rawValue)"
                if let sig = match.signature {
                    line += " \(sig.selectorString)"
                }
                print(line)

                if let ctx = contexts[match], !ctx.isEmpty {
                    printContextCompact(ctx, indent: "    ")
                }
            }
        }
    }

    /// Print symbol usages in compact text format.
    public static func printUsagesText(_ usages: [SymbolOccurrence]) {
        if usages.isEmpty {
            print("(none)")
            return
        }

        let byFile = Dictionary(grouping: usages) { $0.file }
        let sortedFiles = byFile.keys.sorted()

        for file in sortedFiles {
            guard let fileUsages = byFile[file] else { continue }
            let sorted = fileUsages.sorted { $0.line < $1.line }

            print("\n\(file)")
            let formatted = sorted.map { "\($0.line):\($0.column)(\($0.kind.rawValue.prefix(3)))" }
            var currentLine = "  "
            for item in formatted {
                if currentLine.count + item.count > 100 {
                    print(currentLine)
                    currentLine = "  "
                }
                currentLine += item + " "
            }
            if currentLine.count > 2 {
                print(currentLine)
            }
        }
    }

    /// Print context in compact format.
    private static func printContextCompact(_ ctx: SymbolContext, indent: String) {
        if let doc = ctx.documentation, doc.hasContent {
            if let summary = doc.summary {
                print("\(indent)/// \(summary)")
            }
            for param in doc.parameters {
                print("\(indent)/// @param \(param.name): \(param.description)")
            }
            if let returns = doc.returns {
                print("\(indent)/// @returns \(returns)")
            }
            if let throwsDoc = doc.throws {
                print("\(indent)/// @throws \(throwsDoc)")
            }
        }

        if let sig = ctx.completeSignature {
            print("\(indent)sig: \(sig)")
        }

        if !ctx.linesBefore.isEmpty {
            for line in ctx.linesBefore {
                print("\(indent)\(line.lineNumber): \(line.content)")
            }
        }

        if !ctx.linesAfter.isEmpty {
            for line in ctx.linesAfter {
                print("\(indent)\(line.lineNumber): \(line.content)")
            }
        }

        if let body = ctx.body {
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                print("\(indent)| \(line)")
            }
        }

        if let scope = ctx.scopeContent {
            print("\(indent)in: \(scope.kind.rawValue) \(scope.name ?? "") L\(scope.startLine)-\(scope.endLine)")
        }
    }
}
