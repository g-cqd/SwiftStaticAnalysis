//  main.swift
//  SwiftStaticAnalysis
//  MIT License

import ArgumentParser
import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore
import SymbolLookup
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
            Symbol.self,
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

    @Argument(help: "Paths to analyze (directories or files)")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Path to configuration file (.swa.json)")
    var config: String?

    @Option(name: .shortAndLong, help: "Output format (text, json, xcode)")
    var format: OutputFormat = .xcode

    func run() async throws {
        // Use first path for configuration discovery
        let primaryPath = paths.first ?? "."

        // Load configuration
        let swaConfig = try loadConfiguration(configPath: config, analysisPath: primaryPath)

        // Apply format from config if not specified on CLI
        let outputFormat = format

        let files = try findSwiftFiles(in: paths, excludePaths: swaConfig?.excludePaths)

        print("Analyzing \(files.count) Swift files...")

        // Run duplication detection if enabled
        var clones: [CloneGroup] = []
        if swaConfig?.duplicates?.enabled != false {
            let dupConfig = buildDuplicationConfig(from: swaConfig?.duplicates)
            let dupDetector = DuplicationDetector(configuration: dupConfig)
            clones = try await dupDetector.detectClones(in: files)
        }

        // Run unused code detection if enabled
        var unused: [UnusedCode] = []
        if swaConfig?.unused?.enabled != false {
            let unusedConfig = buildUnusedConfig(from: swaConfig?.unused)
            let unusedDetector = UnusedCodeDetector(configuration: unusedConfig)
            unused = try await unusedDetector.detectUnused(in: files)
            unused = applyUnusedFilters(unused, config: swaConfig?.unused)
        }

        // Output results
        outputResults(clones: clones, unused: unused, format: outputFormat)
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

    @Argument(help: "Paths to analyze (directories or files)")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Path to configuration file (.swa.json)")
    var config: String?

    @Option(name: .long, help: "Clone types to detect")
    var types: [CloneTypeArg] = [.exact]

    @Option(name: .long, help: "Minimum tokens for a clone")
    var minTokens: Int?

    @Option(name: .long, help: "Minimum similarity (0.0-1.0)")
    var minSimilarity: Double?

    @Option(name: .long, help: "Detection algorithm (rollingHash, suffixArray, minHashLSH)")
    var algorithm: AlgorithmArg?

    @Option(name: .long, parsing: .upToNextOption, help: "Paths to exclude (glob patterns)")
    var excludePaths: [String] = []

    @Flag(name: .long, help: "Use parallel processing (deprecated: use --parallel-mode)")
    var parallel: Bool = false

    @Option(name: .long, help: "Parallel mode (none, safe, maximum)")
    var parallelMode: ParallelModeArg?

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat = .xcode

    func run() async throws {
        // Use first path for configuration discovery
        let primaryPath = paths.first ?? "."

        // Load configuration
        let swaConfig = try loadConfiguration(configPath: config, analysisPath: primaryPath)
        let dupConfig = swaConfig?.duplicates

        // Merge CLI args with config (CLI takes precedence)
        let effectiveMinTokens = minTokens ?? dupConfig?.minTokens ?? 50
        let effectiveMinSimilarity = minSimilarity ?? dupConfig?.minSimilarity ?? 0.8
        let effectiveAlgorithm = algorithm?.toAlgorithm ?? parseAlgorithm(dupConfig?.algorithm)
        let effectiveTypes = types.isEmpty ? parseCloneTypes(dupConfig?.types) : Set(types.map(\.toCloneType))
        let effectiveExcludePaths = excludePaths.isEmpty ? (dupConfig?.excludePaths ?? []) : excludePaths

        // Resolve parallel mode: CLI --parallel-mode > CLI --parallel > config
        let effectiveParallelMode: ParallelMode =
            if let mode = parallelMode {
                mode.toParallelMode
            } else if parallel {
                .maximum
            } else {
                dupConfig?.resolvedParallelMode ?? .maximum
            }
        let effectiveParallel = effectiveParallelMode.isParallel

        // Merge with global excludePaths
        let allExcludePaths = effectiveExcludePaths + (swaConfig?.excludePaths ?? [])

        let files = try findSwiftFiles(in: paths, excludePaths: allExcludePaths.isEmpty ? nil : allExcludePaths)

        let detectorConfig = DuplicationConfiguration(
            minimumTokens: effectiveMinTokens,
            cloneTypes: effectiveTypes,
            minimumSimilarity: effectiveMinSimilarity,
            algorithm: effectiveAlgorithm,
            useParallelClones: effectiveParallel
        )

        let detector = DuplicationDetector(configuration: detectorConfig)
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

    @Argument(help: "Paths to analyze (directories or files)")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Path to configuration file (.swa.json)")
    var config: String?

    @Flag(name: .long, help: "Ignore public API")
    var ignorePublic: Bool = false

    @Option(name: .long, help: "Detection mode")
    var mode: DetectionModeArg?

    @Option(name: .long, help: "Path to index store")
    var indexStorePath: String?

    @Option(name: .long, help: "Minimum confidence level (low, medium, high)")
    var minConfidence: ConfidenceArg?

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

    // Root treatment flags (use --no-treat-*-as-root to disable)
    @Flag(inversion: .prefixedNo, help: "Treat public API as entry points")
    var treatPublicAsRoot: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat @objc declarations as entry points")
    var treatObjcAsRoot: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat test methods as entry points")
    var treatTestsAsRoot: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat SwiftUI Views as entry points")
    var treatSwiftUIViewsAsRoot: Bool?

    // SwiftUI flags
    @Flag(name: .long, help: "Ignore SwiftUI property wrappers")
    var ignoreSwiftUIPropertyWrappers: Bool = false

    @Flag(name: .long, help: "Ignore PreviewProvider implementations")
    var ignorePreviewProviders: Bool = false

    @Flag(name: .long, help: "Ignore View body properties")
    var ignoreViewBody: Bool = false

    @Flag(name: .long, help: "Use parallel processing (deprecated: use --parallel-mode)")
    var parallel: Bool = false

    @Option(name: .long, help: "Parallel mode (none, safe, maximum)")
    var parallelMode: ParallelModeArg?

    // swiftlint:disable:next function_body_length
    func run() async throws {
        // Use first path for configuration discovery
        let primaryPath = paths.first ?? "."

        // Load configuration
        let swaConfig = try loadConfiguration(configPath: config, analysisPath: primaryPath)
        let unusedConfig = swaConfig?.unused

        // Merge CLI args with config (CLI takes precedence)
        let effectiveMode = mode?.toDetectionMode ?? parseDetectionMode(unusedConfig?.mode)
        let effectiveIndexStorePath = indexStorePath ?? unusedConfig?.indexStorePath
        let effectiveIgnorePublic = ignorePublic || (unusedConfig?.ignorePublicAPI ?? false)
        let effectiveSensibleDefaults = sensibleDefaults || (unusedConfig?.sensibleDefaults ?? false)

        // Merge exclusion settings
        let effectiveExcludeImports =
            excludeImports || (unusedConfig?.excludeImports ?? false) || effectiveSensibleDefaults
        let effectiveExcludeDeinit =
            excludeDeinit || (unusedConfig?.excludeDeinit ?? false) || effectiveSensibleDefaults
        let effectiveExcludeEnumCases =
            excludeEnumCases || (unusedConfig?.excludeEnumCases ?? false) || effectiveSensibleDefaults
        let effectiveExcludeTestSuites =
            excludeTestSuites || (unusedConfig?.excludeTestSuites ?? false) || effectiveSensibleDefaults

        // Merge root treatment settings (CLI > config > default true)
        let effectiveTreatPublicAsRoot = treatPublicAsRoot ?? unusedConfig?.treatPublicAsRoot ?? true
        let effectiveTreatObjcAsRoot = treatObjcAsRoot ?? unusedConfig?.treatObjcAsRoot ?? true
        let effectiveTreatTestsAsRoot = treatTestsAsRoot ?? unusedConfig?.treatTestsAsRoot ?? true
        let effectiveTreatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot ?? unusedConfig?.treatSwiftUIViewsAsRoot ?? true

        // Merge SwiftUI settings
        let effectiveIgnoreSwiftUIPropertyWrappers =
            ignoreSwiftUIPropertyWrappers || (unusedConfig?.ignoreSwiftUIPropertyWrappers ?? false)
        let effectiveIgnorePreviewProviders = ignorePreviewProviders || (unusedConfig?.ignorePreviewProviders ?? false)
        let effectiveIgnoreViewBody = ignoreViewBody || (unusedConfig?.ignoreViewBody ?? false)

        // Resolve parallel mode: CLI --parallel-mode > CLI --parallel > config
        let effectiveParallelMode: ParallelMode =
            if let mode = parallelMode {
                mode.toParallelMode
            } else if parallel {
                .maximum
            } else {
                unusedConfig?.resolvedParallelMode ?? .maximum
            }
        let effectiveParallel = effectiveParallelMode.isParallel

        // Merge path exclusions
        let effectiveExcludePaths = excludePaths.isEmpty ? (unusedConfig?.excludePaths ?? []) : excludePaths
        let allExcludePaths = effectiveExcludePaths + (swaConfig?.excludePaths ?? [])

        var files = try findSwiftFiles(in: paths, excludePaths: allExcludePaths.isEmpty ? nil : allExcludePaths)

        // Apply path exclusions
        if !allExcludePaths.isEmpty {
            files = files.filter { file in
                !allExcludePaths.contains { pattern in
                    UnusedCodeFilter.matchesGlobPattern(file, pattern: pattern)
                }
            }
        }

        let detectorConfig = UnusedCodeConfiguration(
            ignorePublicAPI: effectiveIgnorePublic,
            mode: effectiveMode,
            indexStorePath: effectiveIndexStorePath,
            treatPublicAsRoot: effectiveTreatPublicAsRoot,
            treatObjcAsRoot: effectiveTreatObjcAsRoot,
            treatTestsAsRoot: effectiveTreatTestsAsRoot,
            treatSwiftUIViewsAsRoot: effectiveTreatSwiftUIViewsAsRoot,
            ignoreSwiftUIPropertyWrappers: effectiveIgnoreSwiftUIPropertyWrappers,
            ignorePreviewProviders: effectiveIgnorePreviewProviders,
            ignoreViewBody: effectiveIgnoreViewBody,
            useParallelBFS: effectiveParallel,
        )

        let detector = UnusedCodeDetector(configuration: detectorConfig)

        if report, effectiveMode == .reachability {
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
        let minConf = minConfidence ?? parseConfidence(unusedConfig?.minConfidence)
        unused = filterUnusedResults(
            unused,
            excludeImports: effectiveExcludeImports,
            excludeDeinit: effectiveExcludeDeinit,
            excludeEnumCases: effectiveExcludeEnumCases,
            excludeTestSuites: effectiveExcludeTestSuites,
            minConfidence: minConf,
        )

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

// MARK: - Symbol

struct Symbol: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look up symbols in Swift source files",
    )

    @Argument(help: "Symbol name, qualified name (Type.member), or USR")
    var query: String

    @Argument(help: "Paths to analyze (directories or files)")
    var paths: [String] = ["."]

    @Flag(name: .long, help: "Treat query as USR directly")
    var usr: Bool = false

    @Option(name: .long, help: "Filter by kind (function, method, variable, class, struct, enum, protocol)")
    var kind: [DeclarationKindArg] = []

    @Option(name: .long, help: "Filter by access level (private, internal, public, open)")
    var access: [AccessLevelArg] = []

    @Option(name: .long, help: "Search within type scope")
    var inType: String?

    @Flag(name: .long, help: "Show only definitions")
    var definition: Bool = false

    @Flag(name: .long, help: "Show usages/references")
    var usages: Bool = false

    @Option(name: .long, help: "Path to index store")
    var indexStorePath: String?

    @Option(name: .long, help: "Maximum results to return")
    var limit: Int?

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat = .text

    // Context flags
    @Option(name: .customLong("context-lines"), help: "Lines of context before and after symbol")
    var contextLines: Int?

    @Option(name: .customLong("context-before"), help: "Lines of context before symbol")
    var contextBefore: Int?

    @Option(name: .customLong("context-after"), help: "Lines of context after symbol")
    var contextAfter: Int?

    @Flag(name: .customLong("context-scope"), help: "Include containing scope")
    var contextScope: Bool = false

    @Flag(name: .customLong("context-signature"), help: "Include complete signature")
    var contextSignature: Bool = false

    @Flag(name: .customLong("context-body"), help: "Include declaration body")
    var contextBody: Bool = false

    @Flag(name: .customLong("context-documentation"), help: "Include documentation comments")
    var contextDocumentation: Bool = false

    @Flag(name: .customLong("context-all"), help: "Include all context")
    var contextAll: Bool = false

    func run() async throws {
        let files = try findSwiftFiles(in: paths, excludePaths: nil)

        // Configure symbol finder
        var config = SymbolFinder.Configuration.default
        config.useSyntaxFallback = true
        config.sourceFiles = files

        let finder: SymbolFinder
        if let indexPath = indexStorePath {
            finder = try SymbolFinder(indexStorePath: indexPath, configuration: config)
        } else {
            finder = SymbolFinder(projectPath: paths.first ?? ".", configuration: config)
        }

        // Build query
        let pattern: SymbolQuery.Pattern
        if usr {
            pattern = .usr(query)
        } else {
            let parser = QueryParser()
            pattern = try parser.parse(query)
        }

        let mode: SymbolQuery.Mode =
            if definition {
                .definition
            } else if usages {
                .usages
            } else {
                .all
            }

        let kindFilter: Set<DeclarationKind>? = kind.isEmpty ? nil : Set(kind.map(\.toDeclarationKind))
        let accessFilter: Set<AccessLevel>? = access.isEmpty ? nil : Set(access.map(\.toAccessLevel))

        let symbolQuery = SymbolQuery(
            pattern: pattern,
            kindFilter: kindFilter,
            accessFilter: accessFilter,
            scopeFilter: inType,
            mode: mode,
            limit: limit ?? 0,
        )

        let matches = try await finder.find(symbolQuery)

        // If usages mode was requested, also find usages for each match
        if usages, !matches.isEmpty {
            var allUsages: [SymbolOccurrence] = []
            for match in matches {
                let occurrences = try await finder.findUsages(of: match)
                allUsages.append(contentsOf: occurrences)
            }
            outputUsages(allUsages, matches: matches)
            return
        }

        // Extract context if requested
        let contextConfig = buildContextConfiguration()
        var contexts: [SymbolMatch: SymbolContext] = [:]
        if contextConfig.wantsContext {
            let extractor = SymbolContextExtractor()
            contexts = try await extractor.extractContext(for: matches, configuration: contextConfig)
        }

        // Output results
        outputMatches(matches, contexts: contexts)
    }

    /// Builds context configuration from CLI flags.
    private func buildContextConfiguration() -> SymbolContextConfiguration {
        if contextAll {
            return .all
        }

        // Calculate lines before/after
        let linesBefore = contextBefore ?? contextLines ?? 0
        let linesAfter = contextAfter ?? contextLines ?? 0

        return SymbolContextConfiguration(
            linesBefore: linesBefore,
            linesAfter: linesAfter,
            includeScope: contextScope,
            includeSignature: contextSignature,
            includeBody: contextBody,
            includeDocumentation: contextDocumentation
        )
    }

    private func outputMatches(_ matches: [SymbolMatch], contexts: [SymbolMatch: SymbolContext] = [:]) {
        if matches.isEmpty {
            print("No symbols found matching '\(query)'")
            return
        }

        switch format {
        case .text:
            print("Found \(matches.count) symbol(s):\n")
            for match in matches {
                outputMatchText(match, context: contexts[match])
            }

        case .json:
            outputMatchesJSON(matches, contexts: contexts)

        case .xcode:
            for match in matches {
                let desc = "\(match.kind.rawValue) '\(match.name)'"
                print("\(match.file):\(match.line):\(match.column): note: \(desc)")
            }
        }
    }

    private func outputMatchText(_ match: SymbolMatch, context: SymbolContext?) {
        // Build symbol name with optional signature
        var symbolName = match.name
        if !match.genericParameters.isEmpty {
            symbolName += "<\(match.genericParameters.joined(separator: ", "))>"
        }
        if let sig = match.signature {
            symbolName += sig.selectorString
        }

        var line = "\(match.kind.rawValue) \(symbolName)"
        if let containingType = match.containingType {
            line = "\(containingType).\(line)"
        }
        print("  \(line)")
        print("    Location: \(match.file):\(match.line):\(match.column)")
        print("    Access: \(match.accessLevel.rawValue)")
        if let sig = match.signature {
            print("    Signature: \(sig.displayString)")
        }
        if let usr = match.usr {
            print("    USR: \(usr)")
        }

        // Output context if available
        if let ctx = context, !ctx.isEmpty {
            print()
            outputContextText(ctx)
        }
        print()
    }

    private func outputContextText(_ context: SymbolContext) {
        // Documentation
        if let doc = context.documentation, doc.hasContent {
            print("    Documentation:")
            if let summary = doc.summary {
                print("      \(summary)")
            }
            for param in doc.parameters {
                print("      - Parameter \(param.name): \(param.description)")
            }
            if let returns = doc.returns {
                print("      - Returns: \(returns)")
            }
            if let throwsDoc = doc.throws {
                print("      - Throws: \(throwsDoc)")
            }
        }

        // Complete signature
        if let sig = context.completeSignature {
            print("    Complete Signature:")
            print("      \(sig)")
        }

        // Line context
        if !context.linesBefore.isEmpty || !context.linesAfter.isEmpty {
            print("    Source Context:")
            let allLines = context.linesBefore + context.linesAfter
            let maxLineNum = allLines.map(\.lineNumber).max() ?? 0
            let lineNumWidth = String(maxLineNum).count

            for line in context.linesBefore {
                print("      \(line.formatted(lineNumberWidth: lineNumWidth))")
            }
            for line in context.linesAfter {
                print("      \(line.formatted(lineNumberWidth: lineNumWidth))")
            }
        }

        // Body
        if let body = context.body {
            print("    Body:")
            let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false)
            let preview = bodyLines.prefix(10)
            for bodyLine in preview {
                print("      \(bodyLine)")
            }
            if bodyLines.count > 10 {
                print("      ... (\(bodyLines.count - 10) more lines)")
            }
        }

        // Scope
        if let scope = context.scopeContent {
            print("    Containing Scope: \(scope.kind.rawValue)\(scope.name.map { " '\($0)'" } ?? "")")
            print("      Lines \(scope.startLine)-\(scope.endLine)")
        }
    }

    private func outputMatchesJSON(_ matches: [SymbolMatch], contexts: [SymbolMatch: SymbolContext]) {
        // Build combined output
        struct MatchWithContext: Codable {
            let match: SymbolMatch
            let context: SymbolContext?
        }

        let combined = matches.map { match in
            MatchWithContext(match: match, context: contexts[match])
        }

        OutputFormatter.printJSON(combined)
    }

    private func outputUsages(_ usages: [SymbolOccurrence], matches: [SymbolMatch]) {
        if usages.isEmpty {
            print("No usages found for '\(query)'")
            return
        }

        switch format {
        case .text:
            print("Found \(usages.count) usage(s) of \(matches.count) symbol(s):\n")
            for usage in usages {
                print("  \(usage.locationString) (\(usage.kind.rawValue))")
            }

        case .json:
            OutputFormatter.printJSON(usages)

        case .xcode:
            for usage in usages {
                print("\(usage.file):\(usage.line):\(usage.column): note: Reference (\(usage.kind.rawValue))")
            }
        }
    }
}

// MARK: - DeclarationKindArg

enum DeclarationKindArg: String, ExpressibleByArgument, CaseIterable {
    case function
    case method
    case variable
    case constant
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case initializer

    var toDeclarationKind: DeclarationKind {
        switch self {
        case .function: .function
        case .method: .method
        case .variable: .variable
        case .constant: .constant
        case .class: .class
        case .struct: .struct
        case .enum: .enum
        case .protocol: .protocol
        case .initializer: .initializer
        }
    }
}

// MARK: - AccessLevelArg

enum AccessLevelArg: String, ExpressibleByArgument, CaseIterable {
    case `private`
    case `fileprivate`
    case `internal`
    case `public`
    case `open`

    var toAccessLevel: AccessLevel {
        switch self {
        case .private: .private
        case .fileprivate: .fileprivate
        case .internal: .internal
        case .public: .public
        case .open: .open
        }
    }
}

// MARK: - Configuration Loading Helpers

func loadConfiguration(configPath: String?, analysisPath: String) throws -> SWAConfiguration? {
    let loader = ConfigurationLoader()

    if let configPath {
        // Explicit config path provided
        let url = URL(fileURLWithPath: configPath)
        return try loader.loadFromFile(url)
    }

    // Auto-detect config file in analysis directory
    let analysisURL = URL(fileURLWithPath: analysisPath)
    var searchDirectory = analysisURL

    // If path is a file, search in its parent directory
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: analysisPath, isDirectory: &isDirectory), !isDirectory.boolValue {
        searchDirectory = analysisURL.deletingLastPathComponent()
    }

    return try loader.load(from: searchDirectory)
}

func buildDuplicationConfig(from config: DuplicatesConfiguration?) -> DuplicationConfiguration {
    DuplicationConfiguration(
        minimumTokens: config?.minTokens ?? 50,
        cloneTypes: parseCloneTypes(config?.types),
        minimumSimilarity: config?.minSimilarity ?? 0.8,
        algorithm: parseAlgorithm(config?.algorithm),
    )
}

func buildUnusedConfig(from config: UnusedConfiguration?) -> UnusedCodeConfiguration {
    UnusedCodeConfiguration(
        ignorePublicAPI: config?.ignorePublicAPI ?? false,
        mode: parseDetectionMode(config?.mode),
        indexStorePath: config?.indexStorePath,
        treatPublicAsRoot: config?.treatPublicAsRoot ?? false,
        treatObjcAsRoot: config?.treatObjcAsRoot ?? false,
        treatTestsAsRoot: config?.treatTestsAsRoot ?? false,
        treatSwiftUIViewsAsRoot: config?.treatSwiftUIViewsAsRoot ?? false,
        ignoreSwiftUIPropertyWrappers: config?.ignoreSwiftUIPropertyWrappers ?? false,
        ignorePreviewProviders: config?.ignorePreviewProviders ?? false,
        ignoreViewBody: config?.ignoreViewBody ?? false,
        useParallelBFS: config?.parallel ?? false,
    )
}

func applyUnusedFilters(_ unused: [UnusedCode], config: UnusedConfiguration?) -> [UnusedCode] {
    let sensibleDefaults = config?.sensibleDefaults ?? false
    let excludeImports = config?.excludeImports ?? sensibleDefaults
    let excludeDeinit = config?.excludeDeinit ?? sensibleDefaults
    let excludeEnumCases = config?.excludeEnumCases ?? sensibleDefaults
    let excludeTestSuites = config?.excludeTestSuites ?? sensibleDefaults

    return filterUnusedResults(
        unused,
        excludeImports: excludeImports,
        excludeDeinit: excludeDeinit,
        excludeEnumCases: excludeEnumCases,
        excludeTestSuites: excludeTestSuites,
        minConfidence: nil,
    )
}

func parseCloneTypes(_ types: [String]?) -> Set<CloneType> {
    guard let types, !types.isEmpty else {
        return [.exact]
    }
    return Set(types.compactMap { CloneType(rawValue: $0) })
}

func parseAlgorithm(_ algorithm: String?) -> DetectionAlgorithm {
    guard let algorithm else { return .rollingHash }
    switch algorithm.lowercased() {
    case "rollinghash": return .rollingHash
    case "suffixarray": return .suffixArray
    case "minhashlsh": return .minHashLSH
    default: return .rollingHash
    }
}

func parseDetectionMode(_ mode: String?) -> DetectionMode {
    guard let mode else { return .simple }
    switch mode.lowercased() {
    case "simple": return .simple
    case "reachability": return .reachability
    case "indexstore": return .indexStore
    default: return .simple
    }
}

func parseConfidence(_ confidence: String?) -> ConfidenceArg? {
    guard let confidence else { return nil }
    return ConfidenceArg(rawValue: confidence.lowercased())
}

// swiftlint:disable:next function_parameter_count
func filterUnusedResults(
    _ unused: [UnusedCode],
    excludeImports: Bool,
    excludeDeinit: Bool,
    excludeEnumCases: Bool,
    excludeTestSuites: Bool,
    minConfidence: ConfidenceArg?,
) -> [UnusedCode] {
    var results: [UnusedCode] = []

    for item in unused {
        let name = item.declaration.name

        // Respect swa:ignore directives
        if item.declaration.shouldIgnoreUnused {
            continue
        }

        // Exclude imports
        if excludeImports, item.declaration.kind == .import {
            continue
        }

        // Exclude deinit
        if excludeDeinit, name == "deinit" {
            continue
        }

        // Exclude backticked enum cases
        if excludeEnumCases, name.hasPrefix("`"), name.hasSuffix("`") {
            continue
        }

        // Exclude test suites (names ending with Tests)
        if excludeTestSuites, name.hasSuffix("Tests") {
            continue
        }

        // Filter by minimum confidence
        if let minConf = minConfidence {
            if item.confidence < minConf.toConfidence {
                continue
            }
        }

        results.append(item)
    }

    return results
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

// MARK: - AlgorithmArg

/// Validated algorithm argument for CLI.
enum AlgorithmArg: String, ExpressibleByArgument, CaseIterable {
    case rollingHash
    case suffixArray
    case minHashLSH

    // MARK: Internal

    var toAlgorithm: DetectionAlgorithm {
        switch self {
        case .rollingHash: .rollingHash
        case .suffixArray: .suffixArray
        case .minHashLSH: .minHashLSH
        }
    }
}

// MARK: - ConfidenceArg

/// Validated confidence argument for CLI.
enum ConfidenceArg: String, ExpressibleByArgument, CaseIterable {
    case low
    case medium
    case high

    // MARK: Internal

    var toConfidence: Confidence {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}

// MARK: - ParallelModeArg

/// Validated parallel mode argument for CLI.
enum ParallelModeArg: String, ExpressibleByArgument, CaseIterable {
    case none
    case safe
    case maximum

    // MARK: Internal

    var toParallelMode: ParallelMode {
        switch self {
        case .none: .none
        case .safe: .safe
        case .maximum: .maximum
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
        if let header {
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
            let json = String(data: data, encoding: .utf8)
        {
            print(json)
        }
    }
}

/// Default directories to always exclude from analysis.
/// These contain build artifacts, dependencies, and auto-generated code.
private let defaultExcludedDirectories: Set<String> = [
    ".build",  // Swift Package Manager build artifacts
    "Build",  // Xcode build directory
    "DerivedData",  // Xcode derived data
    ".swiftpm",  // SwiftPM metadata
    "Pods",  // CocoaPods dependencies
    "Carthage",  // Carthage dependencies
    ".git",  // Git metadata
]

// MARK: - Path Canonicalization

/// Canonicalizes a file path to prevent path traversal attacks.
///
/// This function:
/// - Resolves symlinks to their real paths
/// - Resolves `.` and `..` components
/// - Returns the standardized absolute path
///
/// - Parameter path: The raw path to canonicalize.
/// - Returns: The canonicalized path.
/// - Throws: `AnalysisError.invalidPath` if the path cannot be resolved.
func canonicalizePath(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path).standardized

    // Resolve symlinks to prevent symlink attacks
    let resolvedURL: URL
    do {
        resolvedURL = try URL(resolvingAliasFileAt: url, options: [.withoutMounting])
    } catch {
        // If resolution fails, use the standardized path
        resolvedURL = url
    }

    return resolvedURL.path
}

/// Validates that a path doesn't traverse outside expected boundaries.
///
/// - Parameters:
///   - path: The path to validate.
///   - basePath: The expected base directory (if any).
/// - Returns: `true` if the path is within expected boundaries.
func isPathWithinBoundaries(_ path: String, basePath: String?) -> Bool {
    guard let basePath else { return true }

    let normalizedPath = (path as NSString).standardizingPath
    let normalizedBase = (basePath as NSString).standardizingPath

    return normalizedPath.hasPrefix(normalizedBase)
}

func findSwiftFiles(in paths: [String], excludePaths: [String]? = nil) throws -> [String] {
    let fileManager = FileManager.default
    var swiftFiles: [String] = []

    for path in paths {
        // Canonicalize path to prevent path traversal attacks
        let canonicalPath = try canonicalizePath(path)
        let url = URL(fileURLWithPath: canonicalPath)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalPath, isDirectory: &isDirectory) else {
            throw AnalysisError.fileNotFound(canonicalPath)
        }

        if !isDirectory.boolValue {
            // Single file
            guard canonicalPath.hasSuffix(".swift") else {
                throw AnalysisError.invalidPath("Not a Swift file: \(canonicalPath)")
            }
            // Apply exclusion patterns to single files too
            if let excludePaths, !excludePaths.isEmpty {
                let shouldExclude = excludePaths.contains { pattern in
                    UnusedCodeFilter.matchesGlobPattern(canonicalPath, pattern: pattern)
                }
                if shouldExclude {
                    continue
                }
            }
            swiftFiles.append(canonicalPath)
            continue
        }

        // Directory - find all Swift files
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        ) {
            for case let fileURL as URL in enumerator {
                // Skip default excluded directories (even if not hidden)
                let pathComponents = fileURL.pathComponents
                if pathComponents.contains(where: { defaultExcludedDirectories.contains($0) }) {
                    continue
                }

                // Only process Swift files
                guard fileURL.pathExtension == "swift" else {
                    continue
                }

                let filePath = fileURL.path

                // Apply exclusion patterns
                if let excludePaths, !excludePaths.isEmpty {
                    let shouldExclude = excludePaths.contains { pattern in
                        UnusedCodeFilter.matchesGlobPattern(filePath, pattern: pattern)
                    }
                    if shouldExclude {
                        continue
                    }
                }

                swiftFiles.append(filePath)
            }
        }
    }

    return swiftFiles.sorted()
}
