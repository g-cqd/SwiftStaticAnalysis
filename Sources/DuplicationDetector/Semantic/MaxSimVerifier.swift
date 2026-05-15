//  MaxSimVerifier.swift
//  SwiftStaticAnalysis
//  MIT License

#if canImport(CoreML)
    import Foundation

    // MARK: - MaxSimVerifier

    /// Late-interaction (ColBERT-style) similarity for code snippets.
    ///
    /// The pooled-cosine primitive `EmbeddingCloneDiscovery` uses by
    /// default averages 128 per-token vectors into one, which destroys
    /// positional / local-alignment signal. Two snippets that share the
    /// same 10 important tokens in different positions can have low
    /// pooled cosine; two snippets full of boilerplate keywords can
    /// have high pooled cosine even if the actual logic differs.
    ///
    /// MaxSim addresses this by scoring at the token level:
    ///
    ///     MaxSim(A, B) = mean_{a ∈ A} ( max_{b ∈ B} a · b )
    ///
    /// where `·` is the dot product of L2-normalized per-token vectors
    /// (so it's a per-pair cosine). The symmetric form averages the two
    /// directions and is what we use here.
    ///
    /// ## When to use
    ///
    /// - **Reranking**: pass top-K candidates from cosine retrieval
    ///   through MaxSim. Filter by `minMaxSim` to drop shape-only
    ///   false positives that pooled cosine misranks.
    /// - **Diagnostic**: report MaxSim alongside pooled cosine to see
    ///   how much pooling cost on each finding.
    ///
    /// ## Cost
    ///
    /// Per pair: O(m × n × D) where m, n are the snippets' token counts
    /// and D is the embedding dimension. With m = n = 128 and D = 384,
    /// that's ~6.3M FLOPS per pair — acceptable for the top-K
    /// candidates returned by HNSW, not for all O(N²) pairs.
    public struct MaxSimVerifier: Sendable {
        public init() {}

        /// Compute symmetric MaxSim between two per-token embedding
        /// matrices. Each matrix row is one token's L2-normalized
        /// embedding (as produced by
        /// `HFSemanticEmbeddingProvider.embedTokens`).
        public func score(_ a: [[Float]], _ b: [[Float]]) -> Float {
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            return 0.5 * (oneWay(a, b) + oneWay(b, a))
        }

        /// One-directional MaxSim: for every token in `a`, find its best
        /// match in `b`; average those bests.
        private func oneWay(_ a: [[Float]], _ b: [[Float]]) -> Float {
            var total: Float = 0
            for tokenA in a {
                var best: Float = -1
                for tokenB in b {
                    let dim = min(tokenA.count, tokenB.count)
                    var dot: Float = 0
                    for i in 0..<dim {
                        dot += tokenA[i] * tokenB[i]
                    }
                    if dot > best { best = dot }
                }
                total += best
            }
            return total / Float(a.count)
        }
    }
#endif
