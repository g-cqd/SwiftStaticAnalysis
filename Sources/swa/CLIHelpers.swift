//  CLIHelpers.swift
//  swa
//  MIT License
//
//  Configuration-bridge and small parsing helpers used by the `swa`
//  subcommands. Extracted from SWA.swift to shrink the per-subcommand
//  god-file into something reviewers can scan. Each helper preserves
//  its original signature so the move is purely structural.

import ArgumentParser
import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore
import SwiftStaticAnalysisOutput
import SymbolLookup
import UnusedCodeDetector

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

/// Shared embedding-discovery pipeline. Used by both `Duplicates --semantic`
/// and `Analyze --semantic` so the two subcommands stay consistent.
func runUmbrellaEmbeddingDiscovery(
    embedding: EmbeddingOptions, rootPaths: [String]
) async throws -> [CloneGroup] {
    let ctx = try await embedding.loadScanContext(paths: rootPaths)
    guard !ctx.snippets.isEmpty else { return [] }

    let thresholds = embedding.resolvedThresholds()
    let discovery = EmbeddingCloneDiscovery()
    let groups = try await discovery.discover(
        snippets: ctx.snippets,
        provider: ctx.provider,
        k: embedding.k,
        similarityThreshold: thresholds.cosine,
        minTokenOverlap: thresholds.jaccard,
    )

    guard !groups.isEmpty else { return groups }

    // Late-interaction reranks. Four optional gates can be layered on
    // top of cosine + token-Jaccard, each catching a different
    // false-positive class:
    //   * MaxSim    — token-level alignment in embedding space
    //   * AST shape — trigram Jaccard on linearized SwiftSyntax types
    //                 (fast structural approximation)
    //   * APTED     — full tree edit distance (Pawlik-Augsten /
    //                 Zhang-Shasha gold standard; replaces astShape in
    //                 the `strict` preset)
    //   * PDG       — Jaccard over program-dependence-graph fingerprints
    //                 derived from `swiftc -emit-sil`. Catches snippets
    //                 with matching syntax but different SSA def-use
    //                 topology (e.g. swapped operands). Opt-in.
    // A group must pass EVERY enabled rerank to survive.
    let maxSimVerifier = thresholds.maxsim != nil ? MaxSimVerifier() : nil
    let shapeReranker = thresholds.astShape != nil ? ASTShapeReranker() : nil
    let aptedReranker = thresholds.apted != nil ? APTEDReranker() : nil
    let pdgReranker = thresholds.pdg != nil ? PDGReranker() : nil
    guard maxSimVerifier != nil || shapeReranker != nil
        || aptedReranker != nil || pdgReranker != nil
    else {
        return groups
    }

    var kept: [CloneGroup] = []
    kept.reserveCapacity(groups.count)
    outer: for group in groups where group.clones.count >= 2 {
        let aCode = group.clones[0].codeSnippet
        let bCode = group.clones[1].codeSnippet

        if let maxSimVerifier, let maxSimThreshold = thresholds.maxsim {
            do {
                let a = try await ctx.provider.embedTokens(snippet: aCode)
                let b = try await ctx.provider.embedTokens(snippet: bCode)
                if Double(maxSimVerifier.score(a, b)) < maxSimThreshold {
                    continue outer
                }
            } catch {
                // Pre-pooled provider (Gemma) — skip MaxSim gate, fall through.
            }
        }

        if let shapeReranker, let shapeThreshold = thresholds.astShape {
            if shapeReranker.score(aCode, bCode) < shapeThreshold {
                continue outer
            }
        }

        if let aptedReranker, let aptedThreshold = thresholds.apted {
            if aptedReranker.score(aCode, bCode) < aptedThreshold {
                continue outer
            }
        }

        if let pdgReranker, let pdgThreshold = thresholds.pdg {
            // Score is 1.0 when SIL extraction fails for either
            // snippet — the gate falls open instead of pruning a
            // candidate the compiler can't analyse.
            if pdgReranker.score(aCode, bCode) < pdgThreshold {
                continue outer
            }
        }

        kept.append(group)
    }
    return kept
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
