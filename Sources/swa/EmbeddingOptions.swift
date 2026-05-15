//  EmbeddingOptions.swift
//  swa
//  MIT License

import ArgumentParser
import DuplicationDetector
import Foundation

// MARK: - SemanticPreset

/// Threshold preset for semantic clone discovery. Each preset materializes
/// to a `(cosine, jaccard, maxsim)` tuple that's been calibrated on the
/// MiniLM bundle (the recommended default per the β.19 benchmark).
///
/// Why three named presets instead of three numeric flags: the three
/// thresholds interact, the right combination is model-specific, and
/// most users don't know whether 0.85 or 0.92 is right. Naming them
/// `balanced` / `strict` / `loose` ships intent rather than magic numbers.
public enum SemanticPreset: String, ExpressibleByArgument, CaseIterable, Sendable {
    /// Good default. Balanced precision/recall for sentence-transformer
    /// class models. MaxSim rerank off (fast).
    case balanced
    /// High precision. Tight thresholds + MaxSim rerank on. Half the
    /// findings, near-zero false positives. Slower (MaxSim runs O(m·n·D)
    /// per pair).
    case strict
    /// High recall. Loose thresholds to surface fuzzier candidates. Useful
    /// for "give me everything that *might* be related"; expect more noise.
    case loose

    public var thresholds: SemanticThresholds {
        switch self {
        case .balanced:
            return SemanticThresholds(cosine: 0.85, jaccard: 0.20, maxsim: nil, astShape: nil)
        case .strict:
            // Strict = cosine + jaccard + MaxSim (token-level alignment) +
            // AST trigram Jaccard (structural alignment). Either rerank
            // alone catches a different false-positive class.
            return SemanticThresholds(cosine: 0.90, jaccard: 0.30, maxsim: 0.85, astShape: 0.25)
        case .loose:
            return SemanticThresholds(cosine: 0.80, jaccard: 0.10, maxsim: nil, astShape: nil)
        }
    }
}

// MARK: - SemanticThresholds

public struct SemanticThresholds: Sendable {
    public var cosine: Double
    public var jaccard: Double
    /// MaxSim rerank threshold. `nil` disables late-interaction rerank.
    public var maxsim: Double?
    /// AST shape (trigram Jaccard over linearized SwiftSyntax node types)
    /// rerank threshold. `nil` disables structural rerank.
    public var astShape: Double?
}

// MARK: - EmbeddingOptions

/// Shared CLI options for every subcommand that uses an embedding model
/// (`swa duplicates --semantic`, `swa search`, `swa anomaly`,
/// `swa cohesion`). Embedded via `@OptionGroup` so the four subcommands
/// don't redeclare the same flags.
///
/// Bundle auto-discovery: when `--embedding-bundle` is omitted, scans
/// `Models/` for subdirectories and uses the only one. Multiple bundles
/// → explicit error listing them; no `Models/` → explicit error
/// pointing at the integration guide.
public struct EmbeddingOptions: ParsableArguments {
    public init() {}

    @Option(
        name: .customLong("embedding-bundle"),
        help: ArgumentHelp(
            "Directory containing a HF tokenizer + Core ML model.",
            discussion:
                "Auto-discovered when omitted and Models/ has exactly one bundle. "
                + "See INTEGRATION.md for bundle layout.",
        ),
    )
    public var bundle: String?

    @Option(
        name: .customLong("preset"),
        help: ArgumentHelp(
            "Threshold preset for semantic discovery.",
            discussion:
                "balanced (default) = cosine 0.85, jaccard 0.20, no MaxSim. "
                + "strict = cosine 0.90, jaccard 0.30, MaxSim rerank @ 0.85 (slower, higher precision). "
                + "loose = cosine 0.80, jaccard 0.10 (more findings, more noise).",
        ),
    )
    public var preset: SemanticPreset = .balanced

    @Option(
        name: .customLong("embedding-max-length"),
        help: "Max tokens per snippet (default 128 for MiniLM-class models).",
    )
    public var maxLength: Int = 128

    // ---- Advanced overrides (hidden from --help) ----

    @Option(
        name: .customLong("embedding-similarity"),
        help: ArgumentHelp(visibility: .hidden),
    )
    public var similarityOverride: Double?

    @Option(name: .customLong("embedding-k"), help: ArgumentHelp(visibility: .hidden))
    public var kOverride: Int?

    @Option(
        name: .customLong("embedding-min-token-overlap"),
        help: ArgumentHelp(visibility: .hidden),
    )
    public var minTokenOverlapOverride: Double?

    @Flag(
        name: .customLong("embedding-rerank-maxsim"),
        help: ArgumentHelp(visibility: .hidden),
    )
    public var rerankMaxSim: Bool = false

    @Option(
        name: .customLong("embedding-maxsim-threshold"),
        help: ArgumentHelp(visibility: .hidden),
    )
    public var maxSimThresholdOverride: Double?

    @Flag(
        name: .customLong("embedding-rerank-shape"),
        help: ArgumentHelp(visibility: .hidden),
    )
    public var rerankShape: Bool = false

    @Option(
        name: .customLong("embedding-shape-threshold"),
        help: ArgumentHelp(visibility: .hidden),
    )
    public var astShapeThresholdOverride: Double?

    // ---- Resolution helpers ----

    /// Default top-k for HNSW / search / anomaly etc. Overridden by
    /// `--embedding-k` when set.
    public var k: Int { kOverride ?? 10 }

    /// Materialize the effective thresholds, blending preset defaults
    /// with any individual `--embedding-*` overrides.
    public func resolvedThresholds() -> SemanticThresholds {
        var t = preset.thresholds
        if let o = similarityOverride { t.cosine = o }
        if let o = minTokenOverlapOverride { t.jaccard = o }
        if rerankMaxSim || maxSimThresholdOverride != nil {
            t.maxsim = maxSimThresholdOverride ?? t.maxsim ?? 0.85
        }
        if rerankShape || astShapeThresholdOverride != nil {
            t.astShape = astShapeThresholdOverride ?? t.astShape ?? 0.25
        }
        return t
    }

    /// Resolve the bundle path. Order: `--embedding-bundle` →
    /// auto-discover the single bundle under `Models/` → throw with
    /// a clear error.
    public func resolvedBundle() throws -> URL {
        if let bundle, !bundle.isEmpty {
            return URL(fileURLWithPath: bundle)
        }
        let fm = FileManager.default
        let modelsRoot = URL(fileURLWithPath: "Models", isDirectory: true)
        guard fm.fileExists(atPath: modelsRoot.path) else {
            throw ValidationError(
                "No --embedding-bundle provided and Models/ directory not found. "
                    + "Either pass --embedding-bundle <dir> or place a Core ML bundle "
                    + "under Models/<Name>/ (see INTEGRATION.md)."
            )
        }
        let contents =
            (try? fm.contentsOfDirectory(
                at: modelsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
            )) ?? []
        let bundles = contents.filter { url in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            // Require either a model.mlpackage or Model.mlmodelc inside to
            // be considered a real bundle (skip stray files).
            guard isDir.boolValue else { return false }
            let mlpkg = url.appendingPathComponent("Model.mlpackage").path
            let mlmcA = url.appendingPathComponent("Model.mlmodelc").path
            return fm.fileExists(atPath: mlpkg) || fm.fileExists(atPath: mlmcA)
        }
        switch bundles.count {
        case 0:
            throw ValidationError(
                "No --embedding-bundle provided and no bundle found under Models/. "
                    + "Pass --embedding-bundle <dir> or download a bundle (see INTEGRATION.md)."
            )
        case 1:
            return bundles[0]
        default:
            let list = bundles.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw ValidationError(
                "Multiple bundles under Models/: [\(list)]. "
                    + "Pass --embedding-bundle explicitly."
            )
        }
    }

    /// Load the provider against the resolved bundle.
    public func loadProvider() async throws -> HFSemanticEmbeddingProvider {
        let bundleURL = try resolvedBundle()
        return try await HFSemanticEmbeddingProvider(
            bundleDir: bundleURL,
            maxLength: maxLength,
        )
    }
}

// MARK: - EmbeddingScanContext

/// Snippets + their embeddings, the common preparation step every
/// embedding subcommand (`search`, `anomaly`, `cohesion`, semantic
/// `duplicates`) does up-front. Lifted into a shared helper so each
/// subcommand body collapses to "load context → do my math → print".
public struct EmbeddingScanContext: Sendable {
    public let provider: HFSemanticEmbeddingProvider
    public let snippets: [EmbeddingSnippet]
    /// Raw (un-normalized) embeddings from `provider.embed(snippets:)`.
    public let rawVectors: [[Float]]
    /// L2-normalized once; callers do cosine via dot product.
    public let normalizedVectors: [[Float]]
}

extension EmbeddingOptions {
    /// Walk `paths` via `FunctionSnippetExtractor`, load the provider,
    /// embed every snippet, L2-normalize.
    public func loadScanContext(paths: [String]) async throws -> EmbeddingScanContext {
        let provider = try await loadProvider()
        var snippets: [EmbeddingSnippet] = []
        let fm = FileManager.default
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                snippets.append(contentsOf: try FunctionSnippetExtractor.extract(directory: url))
            } else if url.pathExtension == "swift" {
                snippets.append(contentsOf: try FunctionSnippetExtractor.extract(fileURL: url))
            }
        }
        let raw = try await provider.embed(snippets: snippets.map(\.code))
        let normalized = raw.map(SearchMath.l2Normalized)
        return EmbeddingScanContext(
            provider: provider,
            snippets: snippets,
            rawVectors: raw,
            normalizedVectors: normalized,
        )
    }
}
