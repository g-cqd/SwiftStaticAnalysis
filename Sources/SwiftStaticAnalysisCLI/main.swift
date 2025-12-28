//
//  main.swift
//  SwiftStaticAnalysis
//
//  CLI entry point for the `swa` tool.
//

import ArgumentParser
import Foundation
import SwiftStaticAnalysisCore
import DuplicationDetector
import UnusedCodeDetector

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
        defaultSubcommand: Analyze.self
    )
}

// MARK: - Analyze Command

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run full analysis (duplicates + unused code)"
    )

    @Argument(help: "Path to analyze (directory or file)")
    var path: String = "."

    @Option(name: .shortAndLong, help: "Output format (text, json, xcode)")
    var format: OutputFormat = .text

    @Flag(name: .long, help: "Include detailed output")
    var verbose: Bool = false

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

    private func outputResults(
        clones: [CloneGroup],
        unused: [UnusedCode],
        format: OutputFormat
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
        for (index, group) in clones.enumerated() {
            print("\n[\(index + 1)] \(group.type.rawValue) clone (\(group.occurrences) occurrences)")
            for clone in group.clones {
                print("  - \(clone.file):\(clone.startLine)-\(clone.endLine)")
            }
        }

        print("\n=== Unused Code Report ===")
        print("Unused items found: \(unused.count)")
        for item in unused {
            let confidence = "[\(item.confidence.rawValue)]"
            print("\(confidence) \(item.declaration.location): \(item.suggestion)")
        }
    }

    private func outputJSON(clones: [CloneGroup], unused: [UnusedCode]) {
        let report = CombinedReport(clones: clones, unused: unused)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(report),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    private func outputXcode(clones: [CloneGroup], unused: [UnusedCode]) {
        // Output in Xcode-compatible warning format
        for group in clones {
            for clone in group.clones {
                print("\(clone.file):\(clone.startLine): warning: Duplicate code detected (\(group.type.rawValue) clone)")
            }
        }

        for item in unused {
            let loc = item.declaration.location
            print("\(loc.file):\(loc.line):\(loc.column): warning: \(item.suggestion)")
        }
    }
}

// MARK: - Duplicates Command

struct Duplicates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Detect code duplication"
    )

    @Argument(help: "Path to analyze")
    var path: String = "."

    @Option(name: .long, help: "Clone types to detect (exact, near, semantic)")
    var types: [String] = ["exact"]

    @Option(name: .long, help: "Minimum tokens for a clone")
    var minTokens: Int = 50

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat = .text

    func run() async throws {
        let files = try findSwiftFiles(in: path)

        let cloneTypes = Set(types.compactMap { CloneType(rawValue: $0) })

        let config = DuplicationConfiguration(
            minimumTokens: minTokens,
            cloneTypes: cloneTypes.isEmpty ? [.exact] : cloneTypes
        )

        let detector = DuplicationDetector(configuration: config)
        let clones = try await detector.detectClones(in: files)

        print("Found \(clones.count) clone group(s)")
        for group in clones {
            print("- \(group.type.rawValue): \(group.occurrences) occurrences")
        }
    }
}

// MARK: - Unused Command

struct Unused: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Detect unused code"
    )

    @Argument(help: "Path to analyze")
    var path: String = "."

    @Flag(name: .long, help: "Ignore public API")
    var ignorePublic: Bool = false

    @Flag(name: .long, help: "Use index store for accurate detection")
    var useIndexStore: Bool = false

    @Option(name: .long, help: "Path to index store")
    var indexStorePath: String?

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat = .text

    func run() async throws {
        let files = try findSwiftFiles(in: path)

        let config = UnusedCodeConfiguration(
            ignorePublicAPI: ignorePublic,
            useIndexStore: useIndexStore,
            indexStorePath: indexStorePath
        )

        let detector = UnusedCodeDetector(configuration: config)
        let unused = try await detector.detectUnused(in: files)

        print("Found \(unused.count) potentially unused item(s)")
        for item in unused {
            print("[\(item.confidence.rawValue)] \(item.declaration.location): \(item.suggestion)")
        }
    }
}

// MARK: - Helpers

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
    case xcode
}

struct CombinedReport: Codable {
    let clones: [CloneGroup]
    let unused: [UnusedCode]
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
        options: [.skipsHiddenFiles]
    ) {
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "swift" {
                swiftFiles.append(fileURL.path)
            }
        }
    }

    return swiftFiles.sorted()
}
