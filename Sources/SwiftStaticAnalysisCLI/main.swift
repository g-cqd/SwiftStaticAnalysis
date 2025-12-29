//
//  main.swift
//  SwiftStaticAnalysis
//
//  CLI entry point for the `swa` tool.
//

import ArgumentParser
import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore
import UnusedCodeDetector

// MARK: - SWA

@main
struct SWA: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swa",
        abstract: "Swift Static Analysis - Analyze Swift code for issues",
        version: "0.1.0",
        subcommands: [
            Analyze.self,
            Duplicates.self,
            Unused.self,
        ],
        defaultSubcommand: Analyze.self,
    )
}

// MARK: - Analyze

struct Analyze: AsyncParsableCommand {
    // MARK: Internal

    static let configuration = CommandConfiguration(
        abstract: "Run full analysis (duplicates + unused code)",
    )

    @Argument(help: "Path to analyze (directory or file)")
    var path: String = "."

    @Option(name: .shortAndLong, help: "Output format (text, json, xcode)")
    var format: OutputFormat = .xcode

    func run() async throws {
        let files = try findSwiftFiles(in: path)

        print("Analyzing \(files.count) Swift files...")

        // Run duplication detection
        let dupDetector = DuplicationDetector()
        let clones = try await dupDetector.detectClones(in: files)

        // Run unused code detection
        let unusedDetector = UnusedCodeDetector()
        let unused = try await unusedDetector.detectUnused(in: files)

        // Output results
        outputResults(clones: clones, unused: unused, format: format)
    }

    // MARK: Private

    private func outputResults(
        clones: [CloneGroup],
        unused: [UnusedCode],
        format: OutputFormat,
    ) {
        switch format {
        case .text:
            outputText(clones: clones, unused: unused)

        case .json:
            outputJSON(clones: clones, unused: unused)

        case .xcode:
            outputXcode(clones: clones, unused: unused)
        }
    }

    private func outputText(clones: [CloneGroup], unused: [UnusedCode]) {
        print("\n=== Duplication Report ===")
        print("Clone groups found: \(clones.count)")
        OutputFormatter.printCloneGroupsText(clones)

        print("\n=== Unused Code Report ===")
        print("Unused items found: \(unused.count)")
        OutputFormatter.printUnusedText(unused)
    }

    private func outputJSON(clones: [CloneGroup], unused: [UnusedCode]) {
        let report = CombinedReport(clones: clones, unused: unused)
        OutputFormatter.printJSON(report)
    }

    private func outputXcode(clones: [CloneGroup], unused: [UnusedCode]) {
        OutputFormatter.printCloneGroupsXcode(clones)
        OutputFormatter.printUnusedXcode(unused)
    }
}

// MARK: - Duplicates

struct Duplicates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Detect code duplication",
    )

    @Argument(help: "Path to analyze")
    var path: String = "."

    @Option(name: .long, help: "Clone types to detect")
    var types: [CloneTypeArg] = [.exact]

    @Option(name: .long, help: "Minimum tokens for a clone")
    var minTokens: Int = 50

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat = .xcode

    func run() async throws {
        let files = try findSwiftFiles(in: path)

        let cloneTypes = Set(types.map(\.toCloneType))

        let config = DuplicationConfiguration(
            minimumTokens: minTokens,
            cloneTypes: cloneTypes,
        )

        let detector = DuplicationDetector(configuration: config)
        let clones = try await detector.detectClones(in: files)

        switch format {
        case .text:
            print("Found \(clones.count) clone group(s)")
            OutputFormatter.printCloneGroupsText(clones)

        case .json:
            OutputFormatter.printJSON(clones)

        case .xcode:
            OutputFormatter.printCloneGroupsXcode(clones)
        }
    }
}

// MARK: - Unused

struct Unused: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Detect unused code",
    )

    @Argument(help: "Path to analyze")
    var path: String = "."

    @Flag(name: .long, help: "Ignore public API")
    var ignorePublic: Bool = false

    @Option(name: .long, help: "Detection mode")
    var mode: DetectionModeArg = .simple

    @Option(name: .long, help: "Path to index store")
    var indexStorePath: String?

    @Flag(name: .long, help: "Generate reachability report")
    var report: Bool = false

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat = .xcode

    // Exclusion flags
    @Option(name: .long, parsing: .upToNextOption, help: "Paths to exclude (glob patterns)")
    var excludePaths: [String] = []

    @Flag(name: .long, help: "Exclude import statements from results")
    var excludeImports: Bool = false

    @Flag(name: .long, help: "Exclude test suite declarations")
    var excludeTestSuites: Bool = false

    @Flag(name: .long, help: "Exclude backticked enum cases")
    var excludeEnumCases: Bool = false

    @Flag(name: .long, help: "Exclude deinit methods")
    var excludeDeinit: Bool = false

    @Flag(name: .long, help: "Apply sensible defaults (exclude imports, deinit, enum cases)")
    var sensibleDefaults: Bool = false

    func run() async throws {
        var files = try findSwiftFiles(in: path)

        // Apply path exclusions
        let excludePatterns = sensibleDefaults ? excludePaths : excludePaths
        if !excludePatterns.isEmpty {
            files = files.filter { file in
                !excludePatterns.contains { pattern in
                    UnusedCodeFilter.matchesGlobPattern(file, pattern: pattern)
                }
            }
        }

        let detectionMode = mode.toDetectionMode

        let config = UnusedCodeConfiguration(
            ignorePublicAPI: ignorePublic,
            mode: detectionMode,
            indexStorePath: indexStorePath,
        )

        let detector = UnusedCodeDetector(configuration: config)

        if report && detectionMode == .reachability {
            let reachabilityReport = try await detector.generateReachabilityReport(for: files)
            print("=== Reachability Report ===")
            print("Total declarations: \(reachabilityReport.totalDeclarations)")
            print("Root nodes: \(reachabilityReport.rootCount)")
            print("Reachable: \(reachabilityReport.reachableCount)")
            print("Unreachable: \(reachabilityReport.unreachableCount)")
            print("Reachability: \(String(format: "%.1f", reachabilityReport.reachabilityPercentage))%")

            if !reachabilityReport.rootsByReason.isEmpty {
                print("\nRoots by reason:")
                for (reason, count) in reachabilityReport.rootsByReason.sorted(by: { $0.value > $1.value }) {
                    print("  - \(reason.rawValue): \(count)")
                }
            }

            if !reachabilityReport.unreachableByKind.isEmpty {
                print("\nUnreachable by kind:")
                for (kind, count) in reachabilityReport.unreachableByKind.sorted(by: { $0.value > $1.value }) {
                    print("  - \(kind.rawValue): \(count)")
                }
            }
            return
        }

        var unused = try await detector.detectUnused(in: files)

        // Apply exclusion filters
        let shouldExcludeImports = excludeImports || sensibleDefaults
        let shouldExcludeDeinit = excludeDeinit || sensibleDefaults
        let shouldExcludeEnumCases = excludeEnumCases || sensibleDefaults
        let shouldExcludeTestSuites = excludeTestSuites || sensibleDefaults

        unused = unused.filter { item in
            let name = item.declaration.name

            // Respect swa:ignore directives
            if item.declaration.shouldIgnoreUnused {
                return false
            }

            // Exclude imports
            if shouldExcludeImports, item.declaration.kind == .import {
                return false
            }

            // Exclude deinit
            if shouldExcludeDeinit, name == "deinit" {
                return false
            }

            // Exclude backticked enum cases
            if shouldExcludeEnumCases, name.hasPrefix("`"), name.hasSuffix("`") {
                return false
            }

            // Exclude test suites (names ending with Tests)
            if shouldExcludeTestSuites, name.hasSuffix("Tests") {
                return false
            }

            // Exclude based on path patterns
            if !excludePaths.isEmpty {
                let filePath = item.declaration.location.file
                for pattern in excludePaths {
                    if UnusedCodeFilter.matchesGlobPattern(filePath, pattern: pattern) {
                        return false
                    }
                }
            }

            return true
        }

        switch format {
        case .text:
            print("Found \(unused.count) potentially unused item(s)")
            OutputFormatter.printUnusedText(unused)

        case .json:
            OutputFormatter.printJSON(unused)

        case .xcode:
            OutputFormatter.printUnusedXcode(unused)
        }
    }
}

// MARK: - OutputFormat

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
    case xcode
}

// MARK: - CloneTypeArg

/// Validated clone type argument for CLI.
enum CloneTypeArg: String, ExpressibleByArgument, CaseIterable {
    case exact
    case near
    case semantic

    // MARK: Internal

    var toCloneType: CloneType {
        switch self {
        case .exact: .exact
        case .near: .near
        case .semantic: .semantic
        }
    }
}

// MARK: - DetectionModeArg

/// Validated detection mode argument for CLI.
enum DetectionModeArg: String, ExpressibleByArgument, CaseIterable {
    case simple
    case reachability
    case indexStore

    // MARK: Internal

    var toDetectionMode: DetectionMode {
        switch self {
        case .simple: .simple
        case .reachability: .reachability
        case .indexStore: .indexStore
        }
    }
}

// MARK: - CombinedReport

struct CombinedReport: Codable {
    let clones: [CloneGroup]
    let unused: [UnusedCode]
}

// MARK: - OutputFormatter

/// Shared formatting utilities to avoid code duplication across commands.
enum OutputFormatter {
    /// Print clone groups in text format.
    static func printCloneGroupsText(_ clones: [CloneGroup], header: String? = nil) {
        if let header = header {
            print(header)
        }
        for (index, group) in clones.enumerated() {
            print("\n[\(index + 1)] \(group.type.rawValue) clone (\(group.occurrences) occurrences)")
            for clone in group.clones {
                print("  - \(clone.file):\(clone.startLine)-\(clone.endLine)")
            }
        }
    }

    /// Print clone groups in Xcode-compatible warning format.
    static func printCloneGroupsXcode(_ clones: [CloneGroup]) {
        for group in clones {
            for clone in group.clones {
                print(
                    "\(clone.file):\(clone.startLine): warning: Duplicate code detected (\(group.type.rawValue) clone, \(group.occurrences) occurrences)",
                )
            }
        }
    }

    /// Print unused code items in text format.
    static func printUnusedText(_ unused: [UnusedCode]) {
        for item in unused {
            print("[\(item.confidence.rawValue)] \(item.declaration.location): \(item.suggestion)")
        }
    }

    /// Print unused code items in Xcode-compatible warning format.
    static func printUnusedXcode(_ unused: [UnusedCode]) {
        for item in unused {
            let loc = item.declaration.location
            print("\(loc.file):\(loc.line):\(loc.column): warning: \(item.suggestion)")
        }
    }

    /// Encode and print as JSON.
    static func printJSON(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }
}

func findSwiftFiles(in path: String) throws -> [String] {
    let fileManager = FileManager.default
    let url = URL(fileURLWithPath: path)

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw AnalysisError.fileNotFound(path)
    }

    if !isDirectory.boolValue {
        // Single file
        guard path.hasSuffix(".swift") else {
            throw AnalysisError.invalidPath("Not a Swift file: \(path)")
        }
        return [path]
    }

    // Directory - find all Swift files
    var swiftFiles: [String] = []

    if let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles],
    ) {
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "swift" {
                swiftFiles.append(fileURL.path)
            }
        }
    }

    return swiftFiles.sorted()
}
