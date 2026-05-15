//  main.swift
//  SwiftStaticAnalysis
//  MIT License

import ArgumentParser
import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore
import SwiftStaticAnalysisOutput
import SymbolLookup
import Synchronization
import UnusedCodeDetector

// MARK: - Diagnostic Output

/// Write a status message to stderr so that JSON/xcode output redirected to
/// stdout isn't contaminated with progress noise.
func eprint(_ message: String) {
    let line = message + "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

// MARK: - Deprecation Diagnostics

/// Once-per-run diagnostic warnings for deprecated CLI surfaces.
///
/// The warnings emit at most once per process invocation so that scripts
/// using a deprecated flag aren't drowned in repeated diagnostics — exactly
/// one helpful line on stderr, then silence.
enum DeprecatedFlags {
    /// Lock around the warning's one-shot flag; ensures a single stderr
    /// write even when subcommands run in parallel.
    private static let warnedLegacyParallel = Mutex<Bool>(false)

    /// Emit a deprecation warning the first time `--parallel` is observed
    /// in a single run. The flag is preserved through 0.x for backwards
    /// compatibility but always routes through
    /// `ParallelMode.from(legacyParallel:)`, which maps `true → .safe`.
    static func warnLegacyParallel() {
        let firstUse = warnedLegacyParallel.withLock { wasWarned -> Bool in
            defer { wasWarned = true }
            return !wasWarned
        }
        guard firstUse else { return }
        eprint(
            "warning: '--parallel' is deprecated; use '--parallel-mode safe|maximum|none'. "
                + "Legacy '--parallel' now maps to '--parallel-mode safe', matching the .swa.json contract."
        )
    }
}

// MARK: - SWA

@main
struct SWA: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swa",
        abstract: "Swift Static Analysis - Analyze Swift code for issues",
        version: swaVersion,
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
    var format: OutputFormat?

    func run() async throws {
        // Use first path for configuration discovery
        let primaryPath = paths.first ?? "."

        // Load configuration
        let swaConfig = try loadConfiguration(configPath: config, analysisPath: primaryPath)

        // Resolve format: CLI --format > .swa.json top-level format > .xcode.
        let outputFormat = format ?? swaConfig?.format ?? .xcode

        let files = try findSwiftFiles(in: paths, excludePaths: swaConfig?.excludePaths)

        eprint("Analyzing \(files.count) Swift files...")

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

        // Exit code 2 signals "findings exist" to CI. This is the contract
        // that lets `swa analyze . --format xcode` gate a build.
        if !clones.isEmpty || !unused.isEmpty {
            throw ExitCode(2)
        }
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
        print("CLONES \(clones.count) groups")
        OutputFormatter.printCloneGroupsText(clones)

        print("\nUNUSED \(unused.count) items")
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
    var types: [CloneType] = [.exact]

    @Option(name: .long, help: "Minimum tokens for a clone")
    var minTokens: Int?

    @Option(name: .long, help: "Minimum similarity (0.0-1.0)")
    var minSimilarity: Double?

    @Option(name: .long, help: "Detection algorithm (rollingHash, suffixArray, minHashLSH)")
    var algorithm: DetectionAlgorithm?

    @Option(name: .long, parsing: .upToNextOption, help: "Paths to exclude (glob patterns)")
    var excludePaths: [String] = []

    @Flag(name: .long, help: "Use parallel processing (deprecated: use --parallel-mode)")
    var parallel: Bool = false

    @Option(name: .long, help: "Parallel mode (none, safe, maximum)")
    var parallelMode: ParallelMode?

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat?

    /// Argument-level validation. `--min-tokens` is bounded to a sensible
    /// range to prevent crashes (negative or zero) and pathological behaviour
    /// (huge values). `--min-similarity` is a Jaccard ratio.
    func validate() throws {
        if let minTokens, !(1...10_000).contains(minTokens) {
            throw ValidationError("--min-tokens must be between 1 and 10000 (got \(minTokens))")
        }
        if let minSimilarity, !(0.0...1.0).contains(minSimilarity) {
            throw ValidationError("--min-similarity must be between 0.0 and 1.0 (got \(minSimilarity))")
        }
    }

    func run() async throws {
        // Use first path for configuration discovery
        let primaryPath = paths.first ?? "."

        // Load configuration
        let swaConfig = try loadConfiguration(configPath: config, analysisPath: primaryPath)
        let dupConfig = swaConfig?.duplicates

        // Merge CLI args with config (CLI takes precedence)
        let effectiveMinTokens = minTokens ?? dupConfig?.minTokens ?? 50
        let effectiveMinSimilarity = minSimilarity ?? dupConfig?.minSimilarity ?? 0.8
        let effectiveTypes = types.isEmpty ? parseCloneTypes(dupConfig?.types) : Set(types)
        // Per-type algorithm defaults: SA-IS for exact, MinHash+LSH for
        // near and semantic. CLI `--algorithm` and `.swa.json` override
        // still win when set.
        let effectiveAlgorithm =
            algorithm
            ?? parseAlgorithm(dupConfig?.algorithm)
            ?? defaultAlgorithm(forCloneTypes: effectiveTypes)
        let effectiveExcludePaths = excludePaths.isEmpty ? (dupConfig?.excludePaths ?? []) : excludePaths

        // Resolve parallel mode: CLI --parallel-mode > CLI --parallel > config.
        // The deprecated `--parallel` flag maps to `.safe` through the
        // canonical `ParallelMode.from(legacyParallel:)`, matching the
        // `.swa.json` decoder and the README contract.
        let effectiveParallelMode: ParallelMode
        if let mode = parallelMode {
            effectiveParallelMode = mode
        } else if parallel {
            DeprecatedFlags.warnLegacyParallel()
            effectiveParallelMode = ParallelMode.from(legacyParallel: parallel)
        } else {
            effectiveParallelMode = dupConfig?.resolvedParallelMode ?? .maximum
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
            useParallelClones: effectiveParallel,
            useStreamingVerifier: effectiveParallelMode.usesStreamingVerifier,
        )

        let detector = DuplicationDetector(configuration: detectorConfig)
        let clones = try await detector.detectClones(in: files)

        let outputFormat = format ?? swaConfig?.format ?? .xcode
        switch outputFormat {
        case .text:
            print("CLONES \(clones.count) groups")
            OutputFormatter.printCloneGroupsText(clones)

        case .json:
            OutputFormatter.printJSON(clones)

        case .xcode:
            OutputFormatter.printCloneGroupsXcode(clones)
        }

        // Exit code 2 signals "findings exist" to CI.
        if !clones.isEmpty {
            throw ExitCode(2)
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
    var mode: DetectionMode?

    @Option(name: .long, help: "Path to index store")
    var indexStorePath: String?

    @Option(name: .long, help: "Minimum confidence level (low, medium, high)")
    var minConfidence: Confidence?

    @Flag(name: .long, help: "Generate reachability report")
    var report: Bool = false

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat?

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

    @Flag(
        name: .customLong("auto-build"),
        help: "Build the project automatically when the IndexStoreDB is missing or stale (indexStore mode only)"
    )
    var autoBuild: Bool = false

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
    var parallelMode: ParallelMode?

    // swiftlint:disable:next function_body_length
    func run() async throws {
        // Use first path for configuration discovery
        let primaryPath = paths.first ?? "."

        // Load configuration
        let swaConfig = try loadConfiguration(configPath: config, analysisPath: primaryPath)
        let unusedConfig = swaConfig?.unused

        // Merge CLI args with config (CLI takes precedence)
        let effectiveMode = mode ?? parseDetectionMode(unusedConfig?.mode)
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

        // Resolve parallel mode: CLI --parallel-mode > CLI --parallel > config.
        // See `Duplicates.run` for the alignment rationale; both subcommands
        // now route `--parallel` through `ParallelMode.from(legacyParallel:)`.
        //
        // `parallelExplicitlySet` lets the detector know whether to honour
        // the user's choice or fall back to the auto-select threshold for
        // parallel BFS. When the user didn't pass `--parallel-mode` /
        // `--parallel` and `.swa.json` doesn't declare one either, we
        // forward `nil` to `UnusedCodeConfiguration.useParallelBFS` and
        // let `parallelBFSThreshold` make the call.
        let effectiveParallelMode: ParallelMode
        let parallelExplicitlySet: Bool
        if let mode = parallelMode {
            effectiveParallelMode = mode
            parallelExplicitlySet = true
        } else if parallel {
            DeprecatedFlags.warnLegacyParallel()
            effectiveParallelMode = ParallelMode.from(legacyParallel: parallel)
            parallelExplicitlySet = true
        } else if let configMode = unusedConfig?.resolvedParallelMode {
            effectiveParallelMode = configMode
            parallelExplicitlySet = true
        } else {
            effectiveParallelMode = .maximum
            parallelExplicitlySet = false
        }
        let effectiveParallel = effectiveParallelMode.isParallel
        let effectiveUseParallelBFS: Bool? = parallelExplicitlySet ? effectiveParallel : nil

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
            autoBuild: autoBuild,
            treatSwiftUIViewsAsRoot: effectiveTreatSwiftUIViewsAsRoot,
            ignoreSwiftUIPropertyWrappers: effectiveIgnoreSwiftUIPropertyWrappers,
            ignorePreviewProviders: effectiveIgnorePreviewProviders,
            ignoreViewBody: effectiveIgnoreViewBody,
            useParallelBFS: effectiveUseParallelBFS,
        )

        // `--report` is only meaningful in reachability mode (it walks the
        // reachability graph). Surface the misuse instead of silently
        // producing a regular unused-code listing.
        if report, effectiveMode != .reachability {
            throw ValidationError(
                "--report requires --mode reachability (current mode: \(effectiveMode.rawValue))"
            )
        }

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

        let outputFormat = format ?? swaConfig?.format ?? .xcode
        switch outputFormat {
        case .text:
            print("UNUSED \(unused.count) items")
            OutputFormatter.printUnusedText(unused)

        case .json:
            OutputFormatter.printJSON(unused)

        case .xcode:
            OutputFormatter.printUnusedXcode(unused)
        }

        // Exit code 2 signals "findings exist" to CI.
        if !unused.isEmpty {
            throw ExitCode(2)
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
    var kind: [DeclarationKind] = []

    @Option(name: .long, help: "Filter by access level (private, internal, public, open)")
    var access: [AccessLevel] = []

    @Option(name: .long, help: "Search within type scope")
    var inType: String?

    @Flag(name: .long, help: "Show only definitions")
    var definition: Bool = false

    @Flag(name: .long, help: "Show usages/references")
    var usages: Bool = false

    @Option(name: .long, help: "Path to index store")
    var indexStorePath: String?

    @Option(
        name: .customLong("lsp"),
        help: "Workspace root for sourcekit-lsp-backed resolution (build-required mode). When supplied, results include LSP-precision matches (protocol witnesses) merged with IndexStore / syntax results."
    )
    var lspWorkspaceRoot: String?

    @Option(name: .long, help: "Maximum results to return")
    var limit: Int?

    /// Symbol defaults to `xcode` for parity with `analyze`/`duplicates`/`unused`.
    /// Pass `--format text` for human-readable interactive output.
    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat?

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

    func validate() throws {
        if let limit, limit < 1 {
            throw ValidationError("--limit must be >= 1 (got \(limit))")
        }
    }

    func run() async throws {
        let files = try findSwiftFiles(in: paths, excludePaths: nil)

        // Resolve output format: CLI flag > auto-discovered .swa.json top-level
        // > .xcode default. `symbol` has no explicit `--config` flag, so we
        // rely on the loader's auto-discovery from `paths.first`.
        let primaryPath = paths.first ?? "."
        let swaConfig = try loadConfiguration(configPath: nil, analysisPath: primaryPath)
        let outputFormat: OutputFormat = format ?? swaConfig?.format ?? .xcode

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

        let kindFilter: Set<DeclarationKind>? = kind.isEmpty ? nil : Set(kind)
        let accessFilter: Set<AccessLevel>? = access.isEmpty ? nil : Set(access)

        let symbolQuery = SymbolQuery(
            pattern: pattern,
            kindFilter: kindFilter,
            accessFilter: accessFilter,
            scopeFilter: inType,
            mode: mode,
            limit: limit ?? 0,
        )

        var matches = try await finder.find(symbolQuery)

        // Merge LSP-backed results when --lsp <workspace> was supplied.
        // The LSP resolver runs sourcekit-lsp under the build-required
        // mode (sourcekit-lsp needs a building workspace); it finds
        // matches the IndexStore-only resolver misses, notably
        // protocol-witness dispatch targets.
        if let workspaceRoot = lspWorkspaceRoot {
            let lspResolver = LSPSymbolResolver(workspaceRoot: workspaceRoot)
            defer {
                // Best-effort shutdown — we can't await in defer, so
                // schedule a detached task that joins the subprocess.
                Task { await lspResolver.shutdown() }
            }
            do {
                let lspMatches = try await lspResolver.resolve(pattern)
                // Deduplicate by (file, line, column) — LSP and
                // IndexStore frequently agree on a definition's
                // location; we want one entry, not two.
                var seen = Set(matches.map { "\($0.file):\($0.line):\($0.column)" })
                for match in lspMatches {
                    let key = "\(match.file):\(match.line):\(match.column)"
                    if seen.insert(key).inserted {
                        matches.append(match)
                    }
                }
            } catch LSPSymbolResolverError.usrNotSupported {
                // USR queries can't go through LSP; the IndexStore /
                // syntax matches already cover them. Silently continue.
            }
        }

        // If usages mode was requested, also find usages for each match
        if usages, !matches.isEmpty {
            var allUsages: [SymbolOccurrence] = []
            for match in matches {
                let occurrences = try await finder.findUsages(of: match)
                allUsages.append(contentsOf: occurrences)
            }
            outputUsages(allUsages, matches: matches, format: outputFormat)
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
        outputMatches(matches, contexts: contexts, format: outputFormat)
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

    private func outputMatches(
        _ matches: [SymbolMatch],
        contexts: [SymbolMatch: SymbolContext] = [:],
        format outputFormat: OutputFormat
    ) {
        if matches.isEmpty {
            print("No symbols found matching '\(query)'")
            return
        }

        switch outputFormat {
        case .text:
            print("SYMBOLS \(matches.count) matches for '\(query)'")
            OutputFormatter.printSymbolsText(matches, contexts: contexts)

        case .json:
            outputMatchesJSON(matches, contexts: contexts)

        case .xcode:
            for match in matches {
                let desc = "\(match.kind.rawValue) '\(match.name)'"
                print("\(match.file):\(match.line):\(match.column): note: \(desc)")
            }
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

    private func outputUsages(
        _ usages: [SymbolOccurrence],
        matches: [SymbolMatch],
        format outputFormat: OutputFormat
    ) {
        if usages.isEmpty {
            print("No usages found for '\(query)'")
            return
        }

        switch outputFormat {
        case .text:
            print("USAGES \(usages.count) refs of \(matches.count) symbols for '\(query)'")
            OutputFormatter.printUsagesText(usages)

        case .json:
            OutputFormatter.printJSON(usages)

        case .xcode:
            // Emit warning: so Xcode and CI tools gate on usages too.
            // (Was note: which is informational and ignored by build status.)
            for usage in usages {
                print("\(usage.file):\(usage.line):\(usage.column): warning: Reference (\(usage.kind.rawValue))")
            }
        }
    }
}

// `DeclarationKindArg` and `AccessLevelArg` were deleted in 0.2.0. The
// domain enums now conform directly to `ExpressibleByArgument` via the
// retroactive extensions in `CLIConformances.swift`.

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
    // `ignoredPatterns` from `.swa.json` is forwarded into the detector.
    let cloneTypes = parseCloneTypes(config?.types)
    return DuplicationConfiguration(
        minimumTokens: config?.minTokens ?? 50,
        cloneTypes: cloneTypes,
        ignoredPatterns: config?.ignoredPatterns ?? [],
        minimumSimilarity: config?.minSimilarity ?? 0.8,
        algorithm: parseAlgorithm(config?.algorithm) ?? defaultAlgorithm(forCloneTypes: cloneTypes),
    )
}

/// Build an UnusedCodeConfiguration from .swa.json config.
///
/// Defaults match `Unused.run()` *and* `UnusedCodeConfiguration.init`
/// (treat-roots default to `true`, SwiftUI ignores default to `false`).
/// Parallel-mode resolution honours `config.resolvedParallelMode` (the
/// `--parallel-mode safe|maximum` form), with a fallback to the legacy
/// `config.parallel` bool.
func buildUnusedConfig(from config: UnusedConfiguration?) -> UnusedCodeConfiguration {
    // `excludeNamePatterns` from `.swa.json` is forwarded into
    // `UnusedCodeConfiguration.ignoredPatterns`.
    UnusedCodeConfiguration(
        ignorePublicAPI: config?.ignorePublicAPI ?? false,
        mode: parseDetectionMode(config?.mode),
        indexStorePath: config?.indexStorePath,
        ignoredPatterns: config?.excludeNamePatterns ?? [],
        treatPublicAsRoot: config?.treatPublicAsRoot ?? true,
        treatObjcAsRoot: config?.treatObjcAsRoot ?? true,
        treatTestsAsRoot: config?.treatTestsAsRoot ?? true,
        treatSwiftUIViewsAsRoot: config?.treatSwiftUIViewsAsRoot ?? true,
        ignoreSwiftUIPropertyWrappers: config?.ignoreSwiftUIPropertyWrappers ?? false,
        ignorePreviewProviders: config?.ignorePreviewProviders ?? false,
        ignoreViewBody: config?.ignoreViewBody ?? false,
        // .swa.json: honour `parallelMode` / legacy `parallel` only when
        // explicitly declared. Nil hands control to
        // `parallelBFSThreshold` auto-select inside `DependencyExtractor`.
        useParallelBFS: parallelOverride(from: config),
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

/// Returns `nil` when `.swa.json` did not set a parallel preference,
/// matching the auto-select contract in `UnusedCodeConfiguration`.
func parallelOverride(from config: UnusedConfiguration?) -> Bool? {
    if let mode = config?.parallelMode {
        return mode.isParallel
    }
    if let legacy = config?.parallel {
        return ParallelMode.from(legacyParallel: legacy).isParallel
    }
    return nil
}

func parseAlgorithm(_ algorithm: String?) -> DetectionAlgorithm? {
    guard let algorithm else { return nil }
    switch algorithm.lowercased() {
    case "rollinghash": return .rollingHash
    case "suffixarray": return .suffixArray
    case "minhashlsh": return .minHashLSH
    default: return nil
    }
}

/// Default `DetectionAlgorithm` for a set of clone types, used when the
/// user didn't pin one explicitly via `--algorithm` or `.swa.json`.
///
/// - `.exact` alone → `.suffixArray` (true Type-1 with SA-IS).
/// - `.near` and/or `.semantic` (single type) → `.minHashLSH`
///   (MinHash + LSH with SIMD4 Mersenne-61).
/// - Mixed sets → `.rollingHash` (Rabin-Karp services every clone type
///   and avoids paying the SA / MinHash setup cost when the user wants
///   a heterogeneous report).
///
/// Empty sets default to `.rollingHash`; callers should already have
/// populated `effectiveTypes`.
func defaultAlgorithm(forCloneTypes types: Set<CloneType>) -> DetectionAlgorithm {
    guard types.count == 1, let only = types.first else { return .rollingHash }
    switch only {
    case .exact: return .suffixArray
    case .near, .semantic: return .minHashLSH
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

func parseConfidence(_ confidence: String?) -> Confidence? {
    guard let confidence else { return nil }
    return Confidence(rawValue: confidence.lowercased())
}

// swiftlint:disable:next function_parameter_count
func filterUnusedResults(
    _ unused: [UnusedCode],
    excludeImports: Bool,
    excludeDeinit: Bool,
    excludeEnumCases: Bool,
    excludeTestSuites: Bool,
    minConfidence: Confidence?,
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
            if item.confidence < minConf {
                continue
            }
        }

        results.append(item)
    }

    return results
}

// The local `OutputFormat` enum and five `*Arg` mirror enums
// (`CloneTypeArg`, `DetectionModeArg`, `AlgorithmArg`, `ConfidenceArg`,
// `ParallelModeArg`) were deleted in 0.2.0. The domain enums conform
// to `ExpressibleByArgument` directly; see `CLIConformances.swift`.
// `OutputFormat` now lives in `SwiftStaticAnalysisCore`.

// MARK: - CombinedReport

struct CombinedReport: Codable {
    let clones: [CloneGroup]
    let unused: [UnusedCode]
}

// MARK: - OutputFormatter

/// Shared formatting utilities to avoid code duplication across commands.
///
/// Text output is optimized for both human and LLM consumption:
/// - Grouped by file to reduce path repetition
/// - Positional semantics instead of repeated key labels
/// - Minimal markup (indentation over brackets)
/// - Stats/summary at top for quick understanding
enum OutputFormatter {
    // MARK: - Text Format (Compact, LLM-optimized)

    /// Print clone groups in compact text format.
    /// Format: Groups clones by type, shows file:lines compactly.
    static func printCloneGroupsText(_ clones: [CloneGroup], header: String? = nil) {
        if let header { print(header) }
        print(CompactTextFormatter.formatClones(clones, includeHeader: false))
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

    /// Print unused code items in compact text format.
    /// Format: Grouped by file, one line per item with kind/name/line/confidence/reason.
    static func printUnusedText(_ unused: [UnusedCode]) {
        print(CompactTextFormatter.formatUnused(unused, includeHeader: false))
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

    // MARK: - Symbol Output (Compact)

    /// Print symbol matches in compact text format.
    /// Format: Grouped by file, essential info on single lines.
    static func printSymbolsText(_ matches: [SymbolMatch], contexts: [SymbolMatch: SymbolContext] = [:]) {
        if matches.isEmpty {
            print("(none)")
            return
        }

        // Group by file
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

                // Compact context output
                if let ctx = contexts[match], !ctx.isEmpty {
                    printContextCompact(ctx, indent: "    ")
                }
            }
        }
    }

    /// Print symbol usages in compact text format.
    static func printUsagesText(_ usages: [SymbolOccurrence]) {
        if usages.isEmpty {
            print("(none)")
            return
        }

        // Group by file
        let byFile = Dictionary(grouping: usages) { $0.file }
        let sortedFiles = byFile.keys.sorted()

        for file in sortedFiles {
            guard let fileUsages = byFile[file] else { continue }
            let sorted = fileUsages.sorted { $0.line < $1.line }

            print("\n\(file)")
            // Compact format: line:col (kind) on single line, multiple per line if short
            let formatted = sorted.map { "\($0.line):\($0.column)(\($0.kind.rawValue.prefix(3)))" }
            // Print in rows of reasonable width
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
        // Documentation summary
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

        // Complete signature
        if let sig = ctx.completeSignature {
            print("\(indent)sig: \(sig)")
        }

        // Context lines before
        if !ctx.linesBefore.isEmpty {
            for line in ctx.linesBefore {
                print("\(indent)\(line.lineNumber): \(line.content)")
            }
        }

        // Context lines after
        if !ctx.linesAfter.isEmpty {
            for line in ctx.linesAfter {
                print("\(indent)\(line.lineNumber): \(line.content)")
            }
        }

        // Body
        if let body = ctx.body {
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                print("\(indent)| \(line)")
            }
        }

        // Containing scope
        if let scope = ctx.scopeContent {
            print("\(indent)in: \(scope.kind.rawValue) \(scope.name ?? "") L\(scope.startLine)-\(scope.endLine)")
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

// MARK: - File Discovery

func findSwiftFiles(in paths: [String], excludePaths: [String]? = nil) throws -> [String] {
    let fileManager = FileManager.default
    var swiftFiles: [String] = []

    for path in paths {
        // Canonicalize path to prevent path traversal attacks. Use the
        // CWD as the resolution base so relative inputs (`.`, `Sources`)
        // resolve consistently with the rest of the toolchain.
        let canonicalPath = PathUtilities.canonicalize(
            path,
            relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath)
        )
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

        // Directory - find all Swift files.
        //
        // The enumerator follows symlinks by default. We re-resolve each
        // discovered file's canonical path and verify it stays underneath
        // the original directory root, matching the hygiene that
        // `CodebaseContext.findSwiftFiles` applies on the MCP side. A
        // symlink pointing at `/tmp/.build/...` would otherwise sneak
        // generated artifacts into the analysis.
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
        ) {
            let rootPrefix = canonicalPath.hasSuffix("/") ? canonicalPath : canonicalPath + "/"
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

                let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == canonicalPath || resolved.hasPrefix(rootPrefix) else {
                    continue
                }

                let filePath = resolved

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
