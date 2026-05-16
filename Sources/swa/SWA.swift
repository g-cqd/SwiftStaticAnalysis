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
            Search.self,
            Anomaly.self,
            Cohesion.self,
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

    @Flag(
        name: .customLong("semantic"),
        help: "Also run semantic clone discovery (HNSW + embedding model)",
    )
    var semantic: Bool = false

    @OptionGroup(title: "Semantic discovery (use with --semantic)")
    var embedding: EmbeddingOptions

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

        // Optional semantic clone discovery (HNSW + embedding model).
        if semantic {
            let semanticGroups = try await runUmbrellaEmbeddingDiscovery(
                embedding: embedding, rootPaths: paths
            )
            clones.append(contentsOf: semanticGroups)
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

    @Option(name: .long, help: "Parallel mode (none, safe, maximum)")
    var parallelMode: ParallelMode?

    @Option(
        name: .long,
        help: "LSH backend: standard (default), multi-probe, parallel."
    )
    var lshStrategy: LSHStrategyArg = .standard

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Probes per band for --lsh-strategy multi-probe (default 2).",
            visibility: .hidden
        )
    )
    var lshProbesPerBand: Int = 2

    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat?

    @Flag(
        name: .customLong("semantic"),
        help:
            "Enable semantic clone discovery (HNSW + embedding model). Auto-discovers Models/<bundle>.",
    )
    var semantic: Bool = false

    /// Shared embedding configuration (bundle, preset, max-length, advanced
    /// overrides). Only honored when `--semantic` is on. The advanced
    /// per-knob flags (`--embedding-similarity`, `--embedding-min-token-overlap`,
    /// `--embedding-rerank-maxsim`, etc.) are hidden from `--help` and act as
    /// per-call overrides on top of the chosen `--preset`.
    @OptionGroup(title: "Semantic discovery (use with --semantic)")
    var embedding: EmbeddingOptions

    /// Argument-level validation. `--min-tokens` is bounded to a sensible
    /// range to prevent crashes (negative or zero) and pathological behaviour
    /// (huge values). `--min-similarity` is a Jaccard ratio.
    func validate() throws {
        if let minTokens, !(1...10_000).contains(minTokens) {
            throw ValidationError("--min-tokens must be between 1 and 10000 (got \(minTokens))")
        }
        if let minSimilarity, !(0.0...1.0).contains(minSimilarity) {
            throw ValidationError(
                "--min-similarity must be between 0.0 and 1.0 (got \(minSimilarity))")
        }
        if let o = embedding.similarityOverride, !(0.0...1.0).contains(o) {
            throw ValidationError(
                "--embedding-similarity must be between 0.0 and 1.0 (got \(o))"
            )
        }
        if let o = embedding.kOverride, !(1...100).contains(o) {
            throw ValidationError("--embedding-k must be between 1 and 100 (got \(o))")
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
        let effectiveParallelMode: ParallelMode =
            parallelMode ?? dupConfig?.resolvedParallelMode ?? .maximum
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
            lshStrategy: lshStrategy.toLSHStrategy(probesPerBand: lshProbesPerBand),
        )

        let detector = DuplicationDetector(configuration: detectorConfig)
        let structural = try await detector.detectClones(in: files)

        // Embedding-based semantic clone discovery via a downloaded HF
        // model bundle (e.g. MiniLM / CodeBERT / GraphCodeBERT). Recovers
        // Type-2 / Type-3 clones the structural pass misses because
        // identifiers differ. Only runs when `--semantic` is set.
        let semantic: [CloneGroup] =
            semantic
            ? try await runEmbeddingDiscovery(rootPaths: paths)
            : []

        let clones = structural + semantic

        let outputFormat = format ?? swaConfig?.format ?? .xcode
        switch outputFormat {
        case .text:
            if !semantic.isEmpty {
                print(
                    "CLONES \(clones.count) groups (\(structural.count) structural, \(semantic.count) semantic)"
                )
            } else {
                print("CLONES \(clones.count) groups")
            }
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

    /// Run the embedding-based semantic clone discovery pass over the
    /// supplied source roots. Extracts function bodies, embeds via a
    /// HuggingFace model loaded through `HFSemanticEmbeddingProvider`,
    /// and surfaces semantic clone groups via `EmbeddingCloneDiscovery`.
    private func runEmbeddingDiscovery(rootPaths: [String]) async throws -> [CloneGroup] {
        try await runUmbrellaEmbeddingDiscovery(embedding: embedding, rootPaths: rootPaths)
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
        name: .customLong("detect-dead-branches"),
        help: "Run the SCCP-based dead-branch pass: each `if false { ... }` / `if x { ... }` where SCCP proves the condition surfaces as an unused-code finding (reachability mode only)."
    )
    var detectDeadBranches: Bool = false

    @Flag(
        name: .customLong("auto-build"),
        help: "Build the project automatically when the IndexStoreDB is missing or stale (indexStore mode only)"
    )
    var autoBuild: Bool = false

    @Option(
        name: .customLong("lsp"),
        help:
            "Workspace root for sourcekit-lsp-backed false-positive filtering (build-required mode). Each candidate unused declaration is verified against `callHierarchy/incomingCalls`; declarations the LSP server reports as having callers (including protocol-witness dispatch) are dropped from the unused list."
    )
    var lspWorkspaceRoot: String?

    // Root treatment flags (use --no-treat-*-as-root to disable)
    @Flag(inversion: .prefixedNo, help: "Treat public API as entry points")
    var treatPublicAsRoot: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat @objc declarations as entry points")
    var treatObjcAsRoot: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat test methods as entry points")
    var treatTestsAsRoot: Bool?

    @Flag(inversion: .prefixedNo, help: "Treat SwiftUI Views as entry points")
    var treatSwiftUIViewsAsRoot: Bool?

    /// SwiftUI-aware mode. Single flag that bundles the three
    /// previously-separate ignore knobs (property wrappers, preview
    /// providers, View body properties). Equivalent to passing
    /// `--ignore-swiftui-property-wrappers --ignore-preview-providers
    /// --ignore-view-body` together.
    @Flag(
        name: .customLong("swiftui"),
        help: "SwiftUI-aware mode: skip property wrappers, PreviewProvider, View body"
    )
    var swiftUI: Bool = false

    // Individual SwiftUI overrides — hidden from --help. Power users who
    // want fine-grained control can still toggle each independently.
    @Flag(name: .long, help: ArgumentHelp(visibility: .hidden))
    var ignoreSwiftUIPropertyWrappers: Bool = false

    @Flag(name: .long, help: ArgumentHelp(visibility: .hidden))
    var ignorePreviewProviders: Bool = false

    @Flag(name: .long, help: ArgumentHelp(visibility: .hidden))
    var ignoreViewBody: Bool = false

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
        // --swiftui rolls up the three individual ignore-* knobs so users
        // don't have to remember each one.
        let swiftUIShorthand = swiftUI

        // Merge SwiftUI settings
        let effectiveIgnoreSwiftUIPropertyWrappers =
            swiftUIShorthand || ignoreSwiftUIPropertyWrappers
            || (unusedConfig?.ignoreSwiftUIPropertyWrappers ?? false)
        let effectiveIgnorePreviewProviders =
            swiftUIShorthand || ignorePreviewProviders
            || (unusedConfig?.ignorePreviewProviders ?? false)
        let effectiveIgnoreViewBody =
            swiftUIShorthand || ignoreViewBody || (unusedConfig?.ignoreViewBody ?? false)

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

        let files = try findSwiftFiles(in: paths, excludePaths: allExcludePaths.isEmpty ? nil : allExcludePaths)
        // (The post-filter loop that used to live here was dead work —
        // `findSwiftFiles` already applies `excludePaths` internally.)

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
            detectDeadBranches: detectDeadBranches,
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

        // Build-required LSP pass: drop any candidate the LSP server
        // knows is reachable through protocol-witness dispatch or
        // other build-aware mechanisms IndexStoreDB / syntax can't
        // see. Each candidate's declaration position is converted
        // to a `file://` URI + 0-based LSP coordinates and queried
        // via `callHierarchy/incomingCalls`. A non-zero call count
        // means the declaration has callers — drop from the unused
        // list. Errors at the LSP layer (position not callable,
        // server not yet warm) leave the candidate in place.
        if let workspaceRoot = lspWorkspaceRoot {
            let lspResolver = LSPSymbolResolver(workspaceRoot: workspaceRoot)
            var survivors: [UnusedCode] = []
            survivors.reserveCapacity(unused.count)
            for candidate in unused {
                let location = candidate.declaration.location
                let uri = "file://" + location.file
                do {
                    let callCount = try await lspResolver.incomingCallCount(
                        uri: uri,
                        line: max(0, location.line - 1),
                        character: max(0, location.column - 1),
                    )
                    // nil = LSP can't answer for this position (not a
                    // callable, server not ready). Keep the candidate
                    // conservatively. 0 = LSP says no callers. >0 =
                    // LSP found callers → drop.
                    if let count = callCount, count > 0 {
                        continue
                    }
                } catch {
                    // LSP query failed entirely — fail open, keep
                    // the candidate.
                }
                survivors.append(candidate)
            }
            unused = survivors
            // Structured shutdown, awaited inline. The previous
            // `defer { Task { await ... } }` raced process teardown
            // because `defer` returned immediately and the detached
            // Task was unstructured.
            await lspResolver.shutdown()
        }

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
        help:
            "Workspace root for sourcekit-lsp-backed resolution (build-required mode). When supplied, results include LSP-precision matches (protocol witnesses) merged with IndexStore / syntax results."
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
            // Structured shutdown — the prior `defer { Task { ... } }`
            // raced process teardown because `defer` returned without
            // awaiting the detached Task.
            await lspResolver.shutdown()
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
//
// The config-bridge helpers (loadConfiguration, buildDuplicationConfig,
// buildUnusedConfig, parseCloneTypes, parseAlgorithm, defaultAlgorithm,
// parseDetectionMode, parseConfidence, runUmbrellaEmbeddingDiscovery,
// filterUnusedResults, applyUnusedFilters, parallelOverride) moved to
// `CLIHelpers.swift` in Phase 6 of the audit-driven cleanup. The
// `findSwiftFiles` function moved to `FileDiscovery.swift`. Same module,
// same internal access, no semantic change.

