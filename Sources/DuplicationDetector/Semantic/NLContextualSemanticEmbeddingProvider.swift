//  NLContextualSemanticEmbeddingProvider.swift
//  SwiftStaticAnalysis
//  MIT License

#if canImport(NaturalLanguage)
    import Foundation
    import NaturalLanguage

    // MARK: - NLContextualSemanticEmbeddingProvider

    /// A real `SemanticEmbeddingProvider` backed by Apple's
    /// `NLContextualEmbedding` (macOS 14+).
    ///
    /// Produces dense, contextual, sentence-level embeddings without
    /// shipping a model bundle: the NL framework's English contextual
    /// embedding asset is system-provided. Token vectors emitted by
    /// `NLContextualEmbedding.embeddingResult(for:language:)` are
    /// mean-pooled to a single fixed-dimension vector per snippet.
    ///
    /// ## What this captures
    ///
    /// English-language contextual semantics over the snippet's
    /// identifier / comment / keyword stream. It is **not** trained on
    /// code — `CodeBERT` / `GraphCodeBERT` would still beat it on
    /// idiom-level clones. But it IS a real, semantically-grounded
    /// embedding (not the FNV-1a hash bucket fallback that
    /// `DeterministicEmbeddingProvider` returns), so it can recover
    /// Type-2 clones (identifier renames, comment edits) and partial
    /// Type-3 clones the structural detector misses.
    ///
    /// ## Asset availability
    ///
    /// `NLContextualEmbedding` lazily downloads its asset bundle on
    /// first use. If the bundle isn't available and can't be
    /// downloaded (offline CI, sandbox restrictions), `init(language:)`
    /// or `embed(snippet:)` throws
    /// `SemanticEmbeddingError.modelLoadFailed`.
    @available(macOS 14.0, *)
    public struct NLContextualSemanticEmbeddingProvider: SemanticEmbeddingProvider {
        // MARK: Lifecycle

        /// Initialize the provider for `language` (default `.english`).
        ///
        /// Loads the contextual-embedding asset eagerly so a later
        /// `embed(snippet:)` failure is surfaced here at construction
        /// time. Records the asset's dimension as
        /// ``embeddingDimension``.
        public init(language: NLLanguage = .english) throws {
            guard let probe = NLContextualEmbedding(language: language) else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.unsupportedLanguage(language)
                )
            }
            if !probe.hasAvailableAssets {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.assetsUnavailable
                )
            }
            do {
                try probe.load()
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }
            self.embeddingDimension = probe.dimension
            self.language = language
        }

        // MARK: Public

        /// Dimension of every embedding this provider returns.
        public let embeddingDimension: Int

        /// Language the underlying contextual embedding was trained on.
        public let language: NLLanguage

        public func embed(snippet: String) async throws -> [Float] {
            guard let embedding = NLContextualEmbedding(language: language) else {
                throw SemanticEmbeddingError.modelLoadFailed(
                    underlying: NLContextualEmbeddingError.unsupportedLanguage(language)
                )
            }
            do {
                try embedding.load()
            } catch {
                throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
            }

            let result: NLContextualEmbeddingResult
            do {
                result = try embedding.embeddingResult(for: snippet, language: language)
            } catch {
                throw SemanticEmbeddingError.inferenceFailed(reason: error.localizedDescription)
            }

            let dimension = embedding.dimension
            var pooled = [Float](repeating: 0, count: dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: snippet.startIndex..<snippet.endIndex) {
                vector,
                _ in
                guard vector.count == dimension else { return true }
                for i in 0..<dimension {
                    pooled[i] += Float(vector[i])
                }
                tokenCount += 1
                return true
            }

            if tokenCount > 0 {
                let scale = 1.0 / Float(tokenCount)
                for i in 0..<dimension {
                    pooled[i] *= scale
                }
            }
            return pooled
        }
    }

    // MARK: - NLContextualEmbeddingError

    /// Provider-local error reasons. Wrapped by
    /// ``SemanticEmbeddingError/modelLoadFailed(underlying:)`` so callers
    /// can switch on the outer error type.
    public enum NLContextualEmbeddingError: Error, CustomStringConvertible {
        /// The system has no `NLContextualEmbedding` for the requested
        /// language. Try `.english` (the most-likely-available locale).
        case unsupportedLanguage(NLLanguage)
        /// The model assets aren't downloaded and aren't reachable
        /// (offline, sandbox restriction, etc.). Call
        /// `NLContextualEmbedding.requestEmbeddingAssets(...)` from a
        /// surface that has network access before constructing the
        /// provider.
        case assetsUnavailable

        public var description: String {
            switch self {
            case .unsupportedLanguage(let language):
                return "NLContextualEmbedding does not support language: \(language.rawValue)"
            case .assetsUnavailable:
                return
                    "NLContextualEmbedding model assets are not available locally; download them first via NLContextualEmbedding.requestEmbeddingAssets(...)."
            }
        }
    }
#endif
