//  SemanticEmbeddingProvider.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SemanticEmbeddingProvider

/// Produces dense vector embeddings of code snippets for semantic-clone
/// detection. Implementations wrap a code-embedding model (CodeBERT,
/// GraphCodeBERT, CodeT5, or a custom Swift-tuned variant) and return
/// fixed-dimension vectors that capture functional similarity beyond
/// what AST-shape fingerprinting can reach.
///
/// The clone detector pipes a snippet through `embed(snippet:)`, then
/// uses cosine similarity (or ANN search) between embeddings to group
/// functionally equivalent code that differs by idiom (e.g. `for` loop
/// vs `reduce`, recursion vs iteration). Empirically this recovers the
/// recall ceiling that the structural detector hits at ~20-30%.
///
/// ## Status
///
/// No production implementation ships with `0.3.x`. The protocol exists
/// so consumers can plug in:
///
/// - A `CoreMLSemanticEmbeddingProvider` wrapping a `MLModel` bundle
///   (CodeBERT-Swift or GraphCodeBERT exported via `coremltools`).
/// - A remote-API provider (OpenAI text-embedding-3, Anthropic, etc.).
/// - A custom local-model provider for air-gapped deployments.
///
/// The default `UnconfiguredSemanticEmbeddingProvider` throws
/// `SemanticEmbeddingError.notConfigured` on every call so the
/// integration path is explicit rather than silently degrading to
/// structural-only detection. Switching to a real provider requires:
///
/// 1. Wrapping the model in a type that conforms to this protocol.
/// 2. Setting `DuplicationConfiguration.semanticEmbeddingProvider` to
///    that instance (TBD wiring in 0.4.0).
/// 3. Opting in via `--semantic-deep` on the CLI (TBD).
///
/// See `Documentation/SwiftStaticAnalysis.docc/Articles/CloneDetection.md`
/// for the recall-ceiling discussion this provider exists to address.
public protocol SemanticEmbeddingProvider: Sendable {
    /// Dimension of every embedding this provider returns. Callers
    /// validate dimension equality before computing similarity.
    var embeddingDimension: Int { get }

    /// Embed a code snippet into a dense vector. Throws if the
    /// snippet exceeds the provider's context window or if the
    /// model fails to load.
    func embed(snippet: String) async throws -> [Float]

    /// Batch embedding for throughput. Default implementation runs
    /// `embed(snippet:)` serially; providers backed by GPU / Neural
    /// Engine should override to batch into a single inference call.
    func embed(snippets: [String]) async throws -> [[Float]]
}

extension SemanticEmbeddingProvider {
    public func embed(snippets: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(snippets.count)
        for snippet in snippets {
            results.append(try await embed(snippet: snippet))
        }
        return results
    }
}

// MARK: - SemanticEmbeddingError

public enum SemanticEmbeddingError: Error, Sendable, CustomStringConvertible {
    case notConfigured
    case snippetTooLong(actual: Int, limit: Int)
    case modelLoadFailed(underlying: Error)
    case inferenceFailed(reason: String)
    case unsupportedOutputDtype(actual: String)

    public var description: String {
        switch self {
        case .notConfigured:
            return
                "Semantic embedding provider not configured. Plug in a SemanticEmbeddingProvider conformer (Core ML, remote API, etc.) on DuplicationConfiguration."
        case .snippetTooLong(let actual, let limit):
            return "Code snippet of \(actual) tokens exceeds embedding context window (\(limit))."
        case .modelLoadFailed(let underlying):
            return "Failed to load embedding model: \(underlying.localizedDescription)"
        case .inferenceFailed(let reason):
            return "Embedding inference failed: \(reason)"
        case .unsupportedOutputDtype(let actual):
            return
                "Embedding model output dtype \(actual) is not supported; expected float32. "
                + "Re-export the model with `compute_precision=ct.precision.FLOAT32` or convert via MLMultiArray's typed subscript."
        }
    }
}

// MARK: - UnconfiguredSemanticEmbeddingProvider

/// Default `SemanticEmbeddingProvider` for builds that don't ship a
/// model. Every call throws `.notConfigured` so consumers get an
/// actionable error instead of silently degrading to structural-only
/// detection.
public struct UnconfiguredSemanticEmbeddingProvider: SemanticEmbeddingProvider, Sendable {
    public init() {}

    public var embeddingDimension: Int { 0 }

    public func embed(snippet: String) async throws -> [Float] {
        throw SemanticEmbeddingError.notConfigured
    }

    public func embed(snippets: [String]) async throws -> [[Float]] {
        throw SemanticEmbeddingError.notConfigured
    }
}
