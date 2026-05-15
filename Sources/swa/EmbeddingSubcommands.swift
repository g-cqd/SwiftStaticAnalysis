//  EmbeddingSubcommands.swift
//  swa
//  MIT License

import ArgumentParser
import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore

// MARK: - Search

/// `swa search "<query>" <paths>` — semantic code search.
///
/// Walks the supplied paths via `FunctionSnippetExtractor`, embeds each
/// snippet via `HFSemanticEmbeddingProvider`, embeds the query, returns
/// the top-K snippets by cosine similarity. Mirrors the discovery
/// pipeline but with one query vector instead of all-pairs.
struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Semantic code search via embedding similarity",
    )

    @Argument(help: "Natural-language or code-snippet query")
    var query: String

    @Argument(help: "Paths to search (directories or files)")
    var paths: [String] = ["."]

    @Option(
        name: .customLong("embedding-bundle"),
        help: "Directory containing a HF tokenizer + Core ML model",
    )
    var embeddingBundle: String

    @Option(name: .customLong("k"), help: "Number of top matches to return")
    var k: Int = 10

    @Option(name: .customLong("embedding-max-length"), help: "Max tokens per snippet")
    var embeddingMaxLength: Int = 128

    @Option(
        name: .shortAndLong, help: "Output format (text, json)")
    var format: OutputFormat = .text

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: embeddingBundle)
        let provider = try await HFSemanticEmbeddingProvider(
            bundleDir: bundleURL,
            maxLength: embeddingMaxLength,
        )

        var snippets: [EmbeddingSnippet] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                snippets.append(contentsOf: try FunctionSnippetExtractor.extract(directory: url))
            } else if url.pathExtension == "swift" {
                snippets.append(contentsOf: try FunctionSnippetExtractor.extract(fileURL: url))
            }
        }
        guard !snippets.isEmpty else {
            print("No snippets found under \(paths.joined(separator: ", "))")
            return
        }

        let snippetVectors = try await provider.embed(snippets: snippets.map(\.code))
        let queryVector = try await provider.embed(snippet: query)

        // Normalize once.
        let normQuery = SearchMath.l2Normalized(queryVector)
        var results: [(snippetIndex: Int, similarity: Float)] = []
        results.reserveCapacity(snippets.count)
        for (i, vector) in snippetVectors.enumerated() {
            let sim = SearchMath.cosine(normQuery, SearchMath.l2Normalized(vector))
            results.append((i, sim))
        }
        results.sort { $0.similarity > $1.similarity }
        let topK = Array(results.prefix(k))

        switch format {
        case .text:
            print("Query: \(query)")
            print("Top \(topK.count) of \(snippets.count) snippets")
            print()
            for (rank, result) in topK.enumerated() {
                let snippet = snippets[result.snippetIndex]
                let head =
                    snippet.code.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                let trimmed = head.prefix(120)
                let simPct = Int((result.similarity * 100).rounded())
                print(
                    "[\(rank + 1)] \(simPct)%  \(snippet.file):\(snippet.startLine)-\(snippet.endLine)"
                )
                print("    \(trimmed)…")
                print()
            }
        case .json:
            struct Hit: Encodable {
                let rank: Int
                let similarity: Float
                let file: String
                let startLine: Int
                let endLine: Int
                let preview: String
            }
            let hits = topK.enumerated().map { (idx, result) -> Hit in
                let snippet = snippets[result.snippetIndex]
                let head =
                    snippet.code.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                return Hit(
                    rank: idx + 1,
                    similarity: result.similarity,
                    file: snippet.file,
                    startLine: snippet.startLine,
                    endLine: snippet.endLine,
                    preview: String(head.prefix(200)),
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(hits)
            print(String(data: data, encoding: .utf8) ?? "[]")
        case .xcode:
            for result in topK {
                let snippet = snippets[result.snippetIndex]
                let simPct = Int((result.similarity * 100).rounded())
                print(
                    "\(snippet.file):\(snippet.startLine):1: note: search match (\(simPct)% similarity)"
                )
            }
        }
    }
}

// MARK: - Anomaly

/// `swa anomaly <paths>` — find snippets whose embedding is far from
/// every other snippet's. Useful for surfacing accidental complexity,
/// legacy outliers, copy-paste from unfamiliar codebases, or genuinely
/// unique helpers that may be worth promoting to a shared module.
struct Anomaly: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "anomaly",
        abstract: "Find snippets that look unlike everything else (outlier detection)",
    )

    @Argument(help: "Paths to scan (directories or files)")
    var paths: [String] = ["."]

    @Option(name: .customLong("embedding-bundle"), help: "Directory containing the embedding model")
    var embeddingBundle: String

    @Option(name: .customLong("top"), help: "Number of outliers to report")
    var top: Int = 20

    @Option(
        name: .customLong("neighbors"),
        help: "k for kNN — outlier score = mean distance to k nearest snippets",
    )
    var neighbors: Int = 5

    @Option(name: .customLong("embedding-max-length"), help: "Max tokens per snippet")
    var embeddingMaxLength: Int = 128

    @Option(name: .shortAndLong, help: "Output format (text, json)")
    var format: OutputFormat = .text

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: embeddingBundle)
        let provider = try await HFSemanticEmbeddingProvider(
            bundleDir: bundleURL,
            maxLength: embeddingMaxLength,
        )

        var snippets: [EmbeddingSnippet] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                snippets.append(contentsOf: try FunctionSnippetExtractor.extract(directory: url))
            } else if url.pathExtension == "swift" {
                snippets.append(contentsOf: try FunctionSnippetExtractor.extract(fileURL: url))
            }
        }
        guard snippets.count > neighbors else {
            print("Not enough snippets (\(snippets.count)) for k=\(neighbors)-NN outlier scoring")
            return
        }

        let vectors = try await provider.embed(snippets: snippets.map(\.code))
        let normalized = vectors.map(SearchMath.l2Normalized)

        // For each snippet, compute its k-NN mean cosine distance to
        // other snippets. The further the average neighbor, the more
        // anomalous. We exclude same-file overlapping snippets so a
        // long function isn't its own neighbor via shingled rewrites.
        var scores: [(index: Int, score: Float)] = []
        scores.reserveCapacity(snippets.count)
        for i in 0..<snippets.count {
            var sims: [Float] = []
            sims.reserveCapacity(snippets.count)
            for j in 0..<snippets.count {
                if i == j { continue }
                if snippets[i].file == snippets[j].file {
                    let a = snippets[i]
                    let b = snippets[j]
                    if !(a.endLine < b.startLine || b.endLine < a.startLine) {
                        continue
                    }
                }
                sims.append(SearchMath.cosine(normalized[i], normalized[j]))
            }
            sims.sort(by: >)
            let topNeighborSims = sims.prefix(neighbors)
            if topNeighborSims.isEmpty { continue }
            let mean = topNeighborSims.reduce(Float(0), +) / Float(topNeighborSims.count)
            // Anomaly score = 1 - meanNeighborSim. Higher = more outlier-y.
            scores.append((i, 1.0 - mean))
        }
        scores.sort { $0.score > $1.score }
        let topOutliers = Array(scores.prefix(top))

        switch format {
        case .text:
            print("Outliers in \(snippets.count) snippets (kNN k=\(neighbors)):")
            print()
            for (rank, entry) in topOutliers.enumerated() {
                let snippet = snippets[entry.index]
                let head =
                    snippet.code.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                let scorePct = Int((entry.score * 100).rounded())
                print(
                    "[\(rank + 1)] anomaly=\(scorePct)%  \(snippet.file):\(snippet.startLine)-\(snippet.endLine)"
                )
                print("    \(head.prefix(120))…")
                print()
            }
        case .json:
            struct Entry: Encodable {
                let rank: Int
                let anomalyScore: Float
                let file: String
                let startLine: Int
                let endLine: Int
                let preview: String
            }
            let entries = topOutliers.enumerated().map { (idx, e) -> Entry in
                let snippet = snippets[e.index]
                let head =
                    snippet.code.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                return Entry(
                    rank: idx + 1,
                    anomalyScore: e.score,
                    file: snippet.file,
                    startLine: snippet.startLine,
                    endLine: snippet.endLine,
                    preview: String(head.prefix(200)),
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            print(String(data: data, encoding: .utf8) ?? "[]")
        case .xcode:
            for entry in topOutliers {
                let snippet = snippets[entry.index]
                let scorePct = Int((entry.score * 100).rounded())
                print(
                    "\(snippet.file):\(snippet.startLine):1: warning: anomalous snippet (\(scorePct)% anomaly score)"
                )
            }
        }
    }
}

// MARK: - Cohesion

/// `swa cohesion <paths>` — measure intra- vs inter-module embedding
/// similarity. High intra-module similarity + low inter-module similarity
/// = a cohesive module. Inverted = candidate for split / merge.
struct Cohesion: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cohesion",
        abstract: "Aggregate embedding similarity per module to surface (lack of) cohesion",
    )

    @Argument(help: "Paths to scan (directories or files)")
    var paths: [String] = ["."]

    @Option(name: .customLong("embedding-bundle"), help: "Directory containing the embedding model")
    var embeddingBundle: String

    @Option(name: .customLong("embedding-max-length"), help: "Max tokens per snippet")
    var embeddingMaxLength: Int = 128

    @Option(
        name: .customLong("group-by"),
        help:
            "Last N dirname segments to group by (1 = parent dir, 2 = parent+grandparent, etc.)",
    )
    var groupBy: Int = 2

    @Option(name: .shortAndLong, help: "Output format (text, json)")
    var format: OutputFormat = .text

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: embeddingBundle)
        let provider = try await HFSemanticEmbeddingProvider(
            bundleDir: bundleURL,
            maxLength: embeddingMaxLength,
        )

        var snippets: [EmbeddingSnippet] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                snippets.append(contentsOf: try FunctionSnippetExtractor.extract(directory: url))
            } else if url.pathExtension == "swift" {
                snippets.append(contentsOf: try FunctionSnippetExtractor.extract(fileURL: url))
            }
        }
        guard snippets.count >= 4 else {
            print("Not enough snippets (\(snippets.count)) for cohesion analysis")
            return
        }

        let vectors = try await provider.embed(snippets: snippets.map(\.code))
        let normalized = vectors.map(SearchMath.l2Normalized)

        // Group snippets by the last `groupBy` segments of the file's
        // dirname. Strips the filename, then keeps the deepest N segments
        // — that's "module/submodule" for a tree like Sources/<Module>/<File>.
        var module: [Int: String] = [:]
        for (i, snippet) in snippets.enumerated() {
            let parts = snippet.file.split(separator: "/")
            // Drop the trailing filename. Empty path edge case → "<unknown>".
            let dirParts = parts.dropLast()
            let tail = dirParts.suffix(groupBy)
            let key = tail.isEmpty ? "<unknown>" : tail.joined(separator: "/")
            module[i] = String(key)
        }

        // For each module, intra = mean cosine over pairs within;
        // inter = mean cosine over pairs to OTHER modules.
        var byModule: [String: [Int]] = [:]
        for (i, m) in module {
            byModule[m, default: []].append(i)
        }
        guard byModule.count >= 2 else {
            print("Only \(byModule.count) module(s) discovered; need ≥2 for inter-module signal")
            return
        }

        struct Row: Encodable {
            let module: String
            let snippets: Int
            let intra: Float
            let inter: Float
            let cohesion: Float  // intra - inter; positive = cohesive
        }
        var rows: [Row] = []
        for (mod, indices) in byModule {
            guard indices.count >= 2 else { continue }
            var intraSum: Float = 0
            var intraCount = 0
            for i in indices {
                for j in indices where j > i {
                    intraSum += SearchMath.cosine(normalized[i], normalized[j])
                    intraCount += 1
                }
            }
            let intra = intraCount > 0 ? intraSum / Float(intraCount) : 0
            var interSum: Float = 0
            var interCount = 0
            for i in indices {
                for j in 0..<snippets.count where !indices.contains(j) {
                    interSum += SearchMath.cosine(normalized[i], normalized[j])
                    interCount += 1
                }
            }
            let inter = interCount > 0 ? interSum / Float(interCount) : 0
            rows.append(
                Row(
                    module: mod,
                    snippets: indices.count,
                    intra: intra,
                    inter: inter,
                    cohesion: intra - inter,
                ))
        }
        rows.sort { $0.cohesion > $1.cohesion }

        switch format {
        case .text:
            print("Cohesion per module (intra-mod − inter-mod cosine):")
            print()
            let header =
                "module".padded(40) + "  " + "n".padded(6, alignRight: true) + "  "
                + "intra".padded(7, alignRight: true) + "  "
                + "inter".padded(7, alignRight: true) + "  "
                + "cohesion".padded(9, alignRight: true)
            print(header)
            print(String(repeating: "─", count: header.count))
            for row in rows {
                let intraPct = Int((row.intra * 100).rounded())
                let interPct = Int((row.inter * 100).rounded())
                let cohesionPct = Int((row.cohesion * 100).rounded())
                let signedCohesion =
                    row.cohesion > 0 ? "+\(cohesionPct)%" : "\(cohesionPct)%"
                let line =
                    row.module.padded(40) + "  "
                    + "\(row.snippets)".padded(6, alignRight: true) + "  "
                    + "\(intraPct)%".padded(7, alignRight: true) + "  "
                    + "\(interPct)%".padded(7, alignRight: true) + "  "
                    + signedCohesion.padded(9, alignRight: true)
                print(line)
            }
            print()
            print(
                "Higher cohesion = module's snippets resemble each other more than they resemble the rest.")
            print("Negative cohesion = module's snippets are more like other modules — split candidate.")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rows)
            print(String(data: data, encoding: .utf8) ?? "[]")
        case .xcode:
            for row in rows where row.cohesion < 0 {
                let cohPct = Int((row.cohesion * 100).rounded())
                print(
                    "\(row.module):1:1: warning: low cohesion (\(cohPct)%) — split candidate"
                )
            }
        }
    }
}

private extension String {
    /// Pad with spaces to the requested width. ASCII-width only (the
    /// module names this is used with don't contain wide characters).
    func padded(_ width: Int, alignRight: Bool = false) -> String {
        if self.count >= width { return self }
        let padding = String(repeating: " ", count: width - self.count)
        return alignRight ? padding + self : self + padding
    }
}

// MARK: - SearchMath

/// Small math helpers for the embedding subcommands. L2-normalization
/// is done once per vector so cosine = dot product downstream.
enum SearchMath {
    static func l2Normalized(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        guard sumSq > 0 else { return v }
        let inv = 1.0 / sumSq.squareRoot()
        return v.map { $0 * inv }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var acc: Float = 0
        let n = min(a.count, b.count)
        for i in 0..<n { acc += a[i] * b[i] }
        return acc
    }
}
