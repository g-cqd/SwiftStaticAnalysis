//  SemanticConfiguration.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SemanticPreset

/// Threshold preset for semantic clone discovery. Each preset
/// materializes to a `SemanticThresholds` tuple that's been
/// calibrated on the MiniLM bundle (the recommended default per
/// the β.19 benchmark).
///
/// Why three named presets instead of three numeric flags: the three
/// thresholds interact, the right combination is model-specific, and
/// most users don't know whether 0.85 or 0.92 is right. Naming them
/// `balanced` / `strict` / `loose` ships intent rather than magic numbers.
///
/// Moved into `DuplicationDetector` in Phase 5.4 of the audit-driven
/// cleanup. Previously lived as `public` in the `swa` executable target,
/// where the `public` visibility had no effect (library consumers
/// couldn't import an executable). `ExpressibleByArgument` conformance
/// is added by the CLI in `CLIConformances.swift` to keep the
/// `ArgumentParser` dependency out of the library.
public enum SemanticPreset: String, CaseIterable, Sendable {
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
            return SemanticThresholds(
                cosine: 0.85, jaccard: 0.20, maxsim: nil, astShape: nil, apted: nil, pdg: nil)
        case .strict:
            // Strict layers four signals — cosine + token Jaccard +
            // MaxSim (token-level alignment) + APTED (full tree edit
            // distance, the gold-standard structural metric). The
            // trigram approximation (`astShape`) is still selectable
            // via the CLI's hidden `--embedding-rerank-shape` flag for
            // users who want the faster but coarser variant; `strict`
            // uses APTED proper. `pdg` stays nil — opt-in via
            // `--embedding-rerank-pdg` because it requires `swiftc`
            // and the snippet to compile standalone.
            return SemanticThresholds(
                cosine: 0.90, jaccard: 0.30, maxsim: 0.85, astShape: nil, apted: 0.70, pdg: nil)
        case .loose:
            return SemanticThresholds(
                cosine: 0.80, jaccard: 0.10, maxsim: nil, astShape: nil, apted: nil, pdg: nil)
        }
    }
}

// MARK: - SemanticThresholds

/// Tunable thresholds for the embedding-driven clone-discovery
/// pipeline. `nil` on any reranker field disables that gate; the
/// always-on `cosine` and `jaccard` thresholds gate the initial
/// kNN + token-overlap stage before any rerank fires.
public struct SemanticThresholds: Sendable {
    public init(
        cosine: Double,
        jaccard: Double,
        maxsim: Double? = nil,
        astShape: Double? = nil,
        apted: Double? = nil,
        pdg: Double? = nil
    ) {
        self.cosine = cosine
        self.jaccard = jaccard
        self.maxsim = maxsim
        self.astShape = astShape
        self.apted = apted
        self.pdg = pdg
    }

    public var cosine: Double
    public var jaccard: Double
    /// MaxSim rerank threshold. `nil` disables late-interaction rerank.
    public var maxsim: Double?
    /// AST shape (trigram Jaccard over linearized SwiftSyntax node types)
    /// rerank threshold. `nil` disables the trigram rerank.
    public var astShape: Double?
    /// APTED (Pawlik-Augsten tree edit distance, Zhang-Shasha core)
    /// normalized similarity threshold. `nil` disables the APTED rerank.
    /// Score = 1 - (TED / max(treeSize)). Higher = more structurally
    /// similar. Strict preset uses 0.70.
    public var apted: Double?
    /// PDG (program-dependence-graph fingerprint Jaccard) rerank
    /// threshold. `nil` disables the PDG rerank. Requires `swiftc`
    /// available on PATH and the snippet to compile standalone —
    /// snippets that don't compile are scored 1.0 (gate falls open).
    public var pdg: Double?
}
