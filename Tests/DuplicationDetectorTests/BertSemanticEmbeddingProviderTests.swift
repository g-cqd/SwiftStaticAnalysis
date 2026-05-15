//  BertSemanticEmbeddingProviderTests.swift
//  SwiftStaticAnalysis
//  MIT License

#if canImport(CoreML)
    import CoreML
    import Foundation
    import Testing

    @testable import DuplicationDetector

    /// End-to-end integration tests for `BertSemanticEmbeddingProvider`
    /// against a downloaded `sentence-transformers/all-MiniLM-L6-v2`
    /// CoreML bundle.
    ///
    /// Model + vocab live under `Models/` (gitignored). They are produced
    /// by `scripts/convert-minilm.py` or, for the pre-converted form,
    /// downloaded via:
    ///
    /// ```bash
    /// huggingface-cli download wiktorwojcik112/all-MiniLM-L6-v2-coreml \
    ///   --include "coreml/feature-extraction/float32_model.mlpackage/*" \
    ///   --local-dir Models/_hf-tmp
    /// mv Models/_hf-tmp/coreml/feature-extraction/float32_model.mlpackage \
    ///    Models/MiniLM.mlpackage
    /// huggingface-cli download sentence-transformers/all-MiniLM-L6-v2 \
    ///   vocab.txt --local-dir Models/_hf-tmp
    /// mv Models/_hf-tmp/vocab.txt Models/MiniLM-vocab.txt
    /// ```
    ///
    /// When either file is missing on the host, every test below
    /// short-circuits with `withKnownIssue` rather than failing — so the
    /// suite is portable across machines while still exercising the full
    /// pipeline when assets are present.
    @Suite("BERT Semantic Embedding Provider — real model end-to-end")
    struct BertSemanticEmbeddingProviderTests {
        /// Resolve `Models/` relative to the package root. Tests run from
        /// `.build/...` so we walk up to the repo root.
        private static var modelsDir: URL {
            var dir = URL(fileURLWithPath: #filePath, isDirectory: false)
            while dir.pathComponents.count > 1, dir.lastPathComponent != "SwiftStaticAnalysis" {
                dir.deleteLastPathComponent()
            }
            return dir.appendingPathComponent("Models", isDirectory: true)
        }

        private static var modelURL: URL { modelsDir.appendingPathComponent("MiniLM.mlpackage") }
        private static var vocabURL: URL { modelsDir.appendingPathComponent("MiniLM-vocab.txt") }

        /// Returns nil and short-circuits if model assets aren't present.
        private func tryMakeProvider() throws -> BertSemanticEmbeddingProvider? {
            let fm = FileManager.default
            guard fm.fileExists(atPath: Self.modelURL.path),
                fm.fileExists(atPath: Self.vocabURL.path)
            else { return nil }
            return try BertSemanticEmbeddingProvider(
                modelURL: Self.modelURL,
                vocabURL: Self.vocabURL,
                doLowerCase: true,
                maxLength: 256,
                embeddingDimension: 384,
            )
        }

        private func cosine(_ a: [Float], _ b: [Float]) -> Float {
            var dot: Float = 0
            var na: Float = 0
            var nb: Float = 0
            for i in 0..<a.count {
                dot += a[i] * b[i]
                na += a[i] * a[i]
                nb += b[i] * b[i]
            }
            let denom = na.squareRoot() * nb.squareRoot()
            return denom == 0 ? 0 : dot / denom
        }

        @Test("Provider loads and embeds a snippet")
        func loadsAndEmbeds() async throws {
            guard let provider = try tryMakeProvider() else {
                withKnownIssue("MiniLM model assets not present under Models/") {
                    Issue.record("Skipping — see suite docs for download steps")
                }
                return
            }
            let vector = try await provider.embed(
                snippet: "func add(_ a: Int, _ b: Int) -> Int { return a + b }"
            )
            #expect(vector.count == provider.embeddingDimension)
            // L2 norm should be non-zero — real embeddings, not all zeros.
            let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            #expect(norm > 0)
        }

        @Test("Real semantic ranking: clone > unrelated")
        func semanticRankingClonesOverUnrelated() async throws {
            guard let provider = try tryMakeProvider() else {
                withKnownIssue("MiniLM model assets not present under Models/") {
                    Issue.record("Skipping")
                }
                return
            }

            let sumA =
                "func computeSum(numbers: [Int]) -> Int { var total = 0; for n in numbers { total += n }; return total }"
            let sumB =
                "func addValues(values: [Int]) -> Int { var sum = 0; for v in values { sum += v }; return sum }"
            let parseURL =
                "func parseURL(_ s: String) -> URL? { return URL(string: s) }"

            let va = try await provider.embed(snippet: sumA)
            let vb = try await provider.embed(snippet: sumB)
            let vc = try await provider.embed(snippet: parseURL)

            let abSimilarity = cosine(va, vb)
            let acSimilarity = cosine(va, vc)

            // Clones must rank strictly higher than the unrelated snippet.
            #expect(
                abSimilarity > acSimilarity,
                "cosine(sumA, sumB)=\(abSimilarity) should exceed cosine(sumA, parseURL)=\(acSimilarity)",
            )
            // And the clone pair should be in a reasonable semantic range
            // for sentence-transformers (typically > 0.7 for renames).
            #expect(
                abSimilarity > 0.7,
                "clone-pair cosine should be > 0.7, got \(abSimilarity)",
            )
        }

        @Test("Self-scan: discover clone groups across this repo's Sources/")
        func selfScanDiscoversGroups() async throws {
            guard let provider = try tryMakeProvider() else {
                withKnownIssue("MiniLM model assets not present under Models/") {
                    Issue.record("Skipping")
                }
                return
            }

            // Pull a curated set of function-shaped snippets from Sources/.
            // Each `(file, label, code)` is independent input to the
            // discovery pipeline.
            let snippets = curatedSelfScanSnippets()
            #expect(snippets.count >= 6, "expected at least 6 snippets for a meaningful scan")

            // Embed each snippet via the real BERT provider.
            var inputs: [EmbeddingSnippet] = []
            inputs.reserveCapacity(snippets.count)
            for (index, item) in snippets.enumerated() {
                inputs.append(
                    EmbeddingSnippet(
                        file: item.file,
                        startLine: index * 100,  // synthetic; non-overlapping per file
                        endLine: index * 100 + 50,
                        tokenCount: 50,
                        code: item.code,
                    )
                )
            }

            // Calibrate the threshold from a known-similar pair (the FNV-1a
            // hash function and its identifier-renamed twin at indices 0/1).
            // Embedding magnitudes for sentence-transformers vary with
            // snippet length; tying the threshold to a real signal avoids
            // baking in a brittle constant.
            let probeA = try await provider.embed(snippet: snippets[0].code)
            let probeB = try await provider.embed(snippet: snippets[1].code)
            let calibrationCosine = cosine(probeA, probeB)
            let threshold = max(0.5, Double(calibrationCosine) * 0.92)

            // Also compute every pairwise cosine so the print log shows
            // why each group was (or wasn't) formed.
            var pairwiseEmbeddings: [[Float]] = []
            pairwiseEmbeddings.reserveCapacity(snippets.count)
            for snippet in snippets {
                pairwiseEmbeddings.append(try await provider.embed(snippet: snippet.code))
            }

            let discovery = EmbeddingCloneDiscovery()
            let groups = try await discovery.discover(
                snippets: inputs,
                provider: provider,
                k: 5,
                similarityThreshold: threshold,
            )

            print("\n=== SELF-SCAN RESULTS (BERT all-MiniLM-L6-v2) ===")
            print("snippets: \(snippets.count)")
            print("threshold (calibrated): \(String(format: "%.3f", threshold))")
            print(
                "calibration pair cosine (fnv1a vs fnv1a-rename): \(String(format: "%.3f", calibrationCosine))"
            )
            print("\nPairwise cosines (just the > threshold ones):")
            for i in 0..<snippets.count {
                for j in (i + 1)..<snippets.count {
                    let c = cosine(pairwiseEmbeddings[i], pairwiseEmbeddings[j])
                    if Double(c) >= threshold {
                        print(
                            "  \(String(format: "%.3f", c))  [\(i)] \(snippets[i].file)  ↔  [\(j)] \(snippets[j].file)"
                        )
                    }
                }
            }
            print("\nDiscovered groups: \(groups.count)")
            for (i, group) in groups.enumerated() {
                print(
                    "  [\(i)] sim=\(String(format: "%.3f", group.similarity)) members=\(group.clones.count)"
                )
                for clone in group.clones {
                    print(
                        "    \(clone.file): \(clone.codeSnippet.prefix(80).replacingOccurrences(of: "\n", with: " "))…"
                    )
                }
            }
            print("===\n")

            #expect(!groups.isEmpty, "real BERT embeddings + HNSW should find at least one group")
        }

        /// Curated function-shaped snippets pulled (verbatim or near-verbatim) from
        /// this repo's `Sources/`. The set is intentionally mixed: some intended
        /// Type-2 clones (renamed identifiers, same logic) and some unrelated.
        /// Keeping these inline avoids needing SwiftSyntax extraction at test time.
        private func curatedSelfScanSnippets() -> [(file: String, code: String)] {
            [
                (
                    "Sources/SwiftStaticAnalysisCore/Utilities/FNV1a.swift",
                    """
                    public static func hash(_ data: [UInt8]) -> UInt64 {
                        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                        for byte in data { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01B3 }
                        return hash
                    }
                    """
                ),
                (
                    "synthetic/fnv1a-rename.swift",
                    """
                    public static func computeHash(_ bytes: [UInt8]) -> UInt64 {
                        var result: UInt64 = 0xcbf2_9ce4_8422_2325
                        for b in bytes { result ^= UInt64(b); result &*= 0x0000_0100_0000_01B3 }
                        return result
                    }
                    """
                ),
                (
                    "Sources/DuplicationDetector/Semantic/HNSWIndex.swift",
                    """
                    static func normalize(_ v: inout [Float]) {
                        var sumSq: Float = 0
                        for value in v { sumSq += value * value }
                        guard sumSq > 0 else { return }
                        let inv = 1.0 / sqrt(sumSq)
                        for i in 0..<v.count { v[i] *= inv }
                    }
                    """
                ),
                (
                    "synthetic/normalize-rename.swift",
                    """
                    static func l2Normalize(_ vec: inout [Float]) {
                        var s: Float = 0
                        for x in vec { s += x * x }
                        guard s > 0 else { return }
                        let scale = 1.0 / sqrt(s)
                        for k in 0..<vec.count { vec[k] *= scale }
                    }
                    """
                ),
                (
                    "Sources/DuplicationDetector/Semantic/EmbeddingCloneDiscovery.swift",
                    """
                    private func shouldSkipPair(_ a: EmbeddingSnippet, _ b: EmbeddingSnippet) -> Bool {
                        guard a.file == b.file else { return false }
                        return !(a.endLine < b.startLine || b.endLine < a.startLine)
                    }
                    """
                ),
                (
                    "Sources/swa-lsp/main.swift",
                    """
                    @main
                    struct SWALSPCommand: AsyncParsableCommand {
                        static let configuration = CommandConfiguration(commandName: "swa-lsp")
                        mutating func run() async throws { try await LSPServer().run() }
                    }
                    """
                ),
                (
                    "Sources/SwiftStaticAnalysisCore/Utilities/PathUtilities.swift",
                    """
                    public static func canonicalize(_ path: String) -> String {
                        let url = URL(fileURLWithPath: path).standardizedFileURL
                        return url.path
                    }
                    """
                ),
                (
                    "Sources/UnusedCodeDetector/Reachability/ParallelBFS.swift",
                    """
                    func computeReachable(from roots: Set<Int>) -> Set<Int> {
                        var visited: Set<Int> = roots
                        var queue: [Int] = Array(roots)
                        while let node = queue.popLast() {
                            for neighbor in adjacency[node] ?? [] where !visited.contains(neighbor) {
                                visited.insert(neighbor); queue.append(neighbor)
                            }
                        }
                        return visited
                    }
                    """
                ),
            ]
        }
    }
#endif
