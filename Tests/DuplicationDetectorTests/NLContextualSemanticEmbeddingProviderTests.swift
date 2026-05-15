//  NLContextualSemanticEmbeddingProviderTests.swift
//  SwiftStaticAnalysis
//  MIT License

#if canImport(NaturalLanguage)
    import Foundation
    import NaturalLanguage
    import Testing

    @testable import DuplicationDetector

    /// End-to-end integration tests for ``NLContextualSemanticEmbeddingProvider``.
    ///
    /// These tests load Apple's English contextual-embedding asset. The
    /// asset is lazily downloaded on first system use — when it's not
    /// available (offline CI, fresh sandbox), the provider init throws
    /// `modelLoadFailed`. Each test catches that error and short-circuits
    /// with a `withKnownIssue` rather than failing, so this suite is
    /// portable across machines while still exercising the full pipeline
    /// when assets are present.
    @Suite("NL Contextual Embedding Provider — real end-to-end")
    struct NLContextualSemanticEmbeddingProviderTests {
        /// Returns the cosine similarity of two equal-length `[Float]` vectors.
        private func cosine(_ a: [Float], _ b: [Float]) -> Float {
            precondition(a.count == b.count)
            var dot: Float = 0
            var na: Float = 0
            var nb: Float = 0
            for i in 0..<a.count {
                dot += a[i] * b[i]
                na += a[i] * a[i]
                nb += b[i] * b[i]
            }
            let denom = (na.squareRoot() * nb.squareRoot())
            return denom == 0 ? 0 : dot / denom
        }

        /// Attempt to construct the provider; if assets aren't available
        /// on this machine, return nil so the caller can skip.
        private func tryMakeProvider() -> NLContextualSemanticEmbeddingProvider? {
            do {
                return try NLContextualSemanticEmbeddingProvider(language: .english)
            } catch {
                return nil
            }
        }

        @Test("Provider reports a positive embedding dimension")
        func dimensionIsPositive() throws {
            guard let provider = tryMakeProvider() else {
                withKnownIssue("NL contextual embedding assets not available on this host") {
                    Issue.record("NL assets missing")
                }
                return
            }
            #expect(provider.embeddingDimension > 0)
        }

        @Test("Embedding the same snippet twice yields identical vectors")
        func sameSnippetSameVector() async throws {
            guard let provider = tryMakeProvider() else {
                withKnownIssue("NL contextual embedding assets not available on this host") {
                    Issue.record("NL assets missing")
                }
                return
            }
            let snippet =
                "func computeSum(numbers: [Int]) -> Int { var total = 0; for n in numbers { total += n }; return total }"

            let v1 = try await provider.embed(snippet: snippet)
            let v2 = try await provider.embed(snippet: snippet)
            #expect(v1.count == provider.embeddingDimension)
            #expect(v1 == v2, "deterministic embedding for identical input")
        }

        @Test("Functionally-equivalent code is more similar than unrelated code")
        func functionallyEquivalentMoreSimilar() async throws {
            guard let provider = tryMakeProvider() else {
                withKnownIssue("NL contextual embedding assets not available on this host") {
                    Issue.record("NL assets missing")
                }
                return
            }

            // A and B compute the same thing with renamed identifiers
            // (Type-2 clone). C is structurally + semantically different.
            let snippetA =
                "func computeSum(numbers: [Int]) -> Int { var total = 0; for n in numbers { total += n }; return total }"
            let snippetB =
                "func addValues(values: [Int]) -> Int { var sum = 0; for v in values { sum += v }; return sum }"
            let snippetC =
                "func parseURL(_ s: String) -> URL? { return URL(string: s) }"

            let va = try await provider.embed(snippet: snippetA)
            let vb = try await provider.embed(snippet: snippetB)
            let vc = try await provider.embed(snippet: snippetC)

            let abSimilarity = cosine(va, vb)
            let acSimilarity = cosine(va, vc)

            // A's clone (B) must be measurably closer than the unrelated
            // snippet (C). Threshold is loose because NL is trained on
            // English, not code — we just need the direction right.
            #expect(
                abSimilarity > acSimilarity,
                "cosine(A,B)=\(abSimilarity) should exceed cosine(A,C)=\(acSimilarity)"
            )
        }

        @Test(
            "EmbeddingCloneDiscovery surfaces a real semantic clone group end-to-end"
        )
        func discoveryFindsSemanticClonesEndToEnd() async throws {
            guard let provider = tryMakeProvider() else {
                withKnownIssue("NL contextual embedding assets not available on this host") {
                    Issue.record("NL assets missing")
                }
                return
            }

            let snippets: [EmbeddingSnippet] = [
                EmbeddingSnippet(
                    file: "alpha.swift",
                    startLine: 1,
                    endLine: 5,
                    tokenCount: 20,
                    code:
                        "func computeSum(numbers: [Int]) -> Int { var total = 0; for n in numbers { total += n }; return total }",
                ),
                EmbeddingSnippet(
                    file: "beta.swift",
                    startLine: 1,
                    endLine: 5,
                    tokenCount: 20,
                    code:
                        "func addValues(values: [Int]) -> Int { var sum = 0; for v in values { sum += v }; return sum }",
                ),
                EmbeddingSnippet(
                    file: "gamma.swift",
                    startLine: 1,
                    endLine: 5,
                    tokenCount: 20,
                    code:
                        "func parseURL(_ s: String) -> URL? { return URL(string: s) }",
                ),
                EmbeddingSnippet(
                    file: "delta.swift",
                    startLine: 1,
                    endLine: 5,
                    tokenCount: 20,
                    code:
                        "actor Counter { var count = 0; func bump() { count += 1 } }",
                ),
            ]

            let discovery = EmbeddingCloneDiscovery()

            // Compute a tight, data-driven threshold:
            // pick the cosine of the closest functionally-equivalent pair
            // (alpha vs beta) as the floor.
            let va = try await provider.embed(snippet: snippets[0].code)
            let vb = try await provider.embed(snippet: snippets[1].code)
            let abSimilarity = Double(cosine(va, vb))
            // Use 90% of that as the threshold so the genuine clone clears.
            let threshold = max(0.5, abSimilarity * 0.9)

            let groups = try await discovery.discover(
                snippets: snippets,
                provider: provider,
                k: 4,
                similarityThreshold: threshold,
            )

            // At least the alpha/beta sum-of-array pair should form a
            // group. (The NL embedding is English-trained, not
            // code-trained, so we keep the assertion modest.)
            #expect(!groups.isEmpty, "expected at least one semantic clone group")
            let combinedFiles = Set(groups.flatMap { $0.clones.map(\.file) })
            #expect(
                combinedFiles.contains("alpha.swift") && combinedFiles.contains("beta.swift"),
                "alpha.swift and beta.swift should share a discovered group"
            )
        }
    }
#endif
