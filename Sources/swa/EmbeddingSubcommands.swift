//  EmbeddingSubcommands.swift
//  swa
//  MIT License

import ArgumentParser
import DuplicationDetector
import Foundation
import SwiftStaticAnalysisCore

// MARK: - Search

/// `swa search "<query>" <paths>` — semantic code search.
struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Semantic code search via embedding similarity",
    )

    @Argument(help: "Natural-language or code-snippet query")
    var query: String

    @Argument(help: "Paths to search (directories or files)")
    var paths: [String] = ["."]

    @OptionGroup(title: "Embedding") var embedding: EmbeddingOptions

    @Option(name: .customLong("k"), help: "Number of top matches to return")
    var k: Int = 10

    @Option(name: .shortAndLong, help: "Output format (text, json, xcode)")
    var format: OutputFormat = .text

    func run() async throws {
        let ctx = try await embedding.loadScanContext(paths: paths)
        guard !ctx.snippets.isEmpty else {
            print("No snippets found under \(paths.joined(separator: ", "))")
            return
        }

        let queryVector = try await ctx.provider.embed(snippet: query)
        let normQuery = SearchMath.l2Normalized(queryVector)

        var results: [(snippetIndex: Int, similarity: Float)] = []
        results.reserveCapacity(ctx.snippets.count)
        for (i, vector) in ctx.normalizedVectors.enumerated() {
            results.append((i, SearchMath.cosine(normQuery, vector)))
        }
        results.sort { $0.similarity > $1.similarity }
        let topK = Array(results.prefix(k))

        switch format {
        case .text:
            print("Query: \(query)")
            print("Top \(topK.count) of \(ctx.snippets.count) snippets")
            print()
            for (rank, result) in topK.enumerated() {
                let snippet = ctx.snippets[result.snippetIndex]
                let head =
                    snippet.code.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                let simPct = Int((result.similarity * 100).rounded())
                print(
                    "[\(rank + 1)] \(simPct)%  \(snippet.file):\(snippet.startLine)-\(snippet.endLine)"
                )
                print("    \(head.prefix(120))…")
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
                let snippet = ctx.snippets[result.snippetIndex]
                let head =
                    snippet.code.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                return Hit(
                    rank: idx + 1, similarity: result.similarity,
                    file: snippet.file, startLine: snippet.startLine, endLine: snippet.endLine,
                    preview: String(head.prefix(200))
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(hits)
            print(String(data: data, encoding: .utf8) ?? "[]")
        case .xcode:
            for result in topK {
                let snippet = ctx.snippets[result.snippetIndex]
                let simPct = Int((result.similarity * 100).rounded())
                print(
                    "\(snippet.file):\(snippet.startLine):1: note: search match (\(simPct)% similarity)"
                )
            }
        }
    }
}

// MARK: - Anomaly

/// `swa anomaly <paths>` — kNN outlier detection.
struct Anomaly: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "anomaly",
        abstract: "Find snippets that look unlike everything else (outlier detection)",
    )

    @Argument(help: "Paths to scan (directories or files)")
    var paths: [String] = ["."]

    @OptionGroup(title: "Embedding") var embedding: EmbeddingOptions

    @Option(name: .customLong("top"), help: "Number of outliers to report")
    var top: Int = 20

    @Option(
        name: .customLong("neighbors"),
        help: "k for kNN — outlier score = mean distance to k nearest snippets",
    )
    var neighbors: Int = 5

    @Option(name: .shortAndLong, help: "Output format (text, json, xcode)")
    var format: OutputFormat = .text

    func run() async throws {
        let ctx = try await embedding.loadScanContext(paths: paths)
        guard ctx.snippets.count > neighbors else {
            print(
                "Not enough snippets (\(ctx.snippets.count)) for k=\(neighbors)-NN outlier scoring"
            )
            return
        }

        var scores: [(index: Int, score: Float)] = []
        scores.reserveCapacity(ctx.snippets.count)
        for i in 0..<ctx.snippets.count {
            var sims: [Float] = []
            sims.reserveCapacity(ctx.snippets.count)
            for j in 0..<ctx.snippets.count where i != j {
                let a = ctx.snippets[i]
                let b = ctx.snippets[j]
                // Skip same-file overlapping snippets.
                if a.file == b.file,
                    !(a.endLine < b.startLine || b.endLine < a.startLine)
                {
                    continue
                }
                sims.append(SearchMath.cosine(ctx.normalizedVectors[i], ctx.normalizedVectors[j]))
            }
            sims.sort(by: >)
            let topNeighbors = sims.prefix(neighbors)
            if topNeighbors.isEmpty { continue }
            let mean = topNeighbors.reduce(Float(0), +) / Float(topNeighbors.count)
            scores.append((i, 1.0 - mean))
        }
        scores.sort { $0.score > $1.score }
        let topOutliers = Array(scores.prefix(top))

        switch format {
        case .text:
            print("Outliers in \(ctx.snippets.count) snippets (kNN k=\(neighbors)):")
            print()
            for (rank, entry) in topOutliers.enumerated() {
                let snippet = ctx.snippets[entry.index]
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
                let snippet = ctx.snippets[e.index]
                let head =
                    snippet.code.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                return Entry(
                    rank: idx + 1, anomalyScore: e.score,
                    file: snippet.file, startLine: snippet.startLine, endLine: snippet.endLine,
                    preview: String(head.prefix(200))
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            print(String(data: data, encoding: .utf8) ?? "[]")
        case .xcode:
            for entry in topOutliers {
                let snippet = ctx.snippets[entry.index]
                let scorePct = Int((entry.score * 100).rounded())
                print(
                    "\(snippet.file):\(snippet.startLine):1: warning: anomalous snippet (\(scorePct)% anomaly score)"
                )
            }
        }
    }
}

// MARK: - Cohesion

/// `swa cohesion <paths>` — per-module intra-vs-inter cosine.
struct Cohesion: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cohesion",
        abstract: "Aggregate embedding similarity per module to surface (lack of) cohesion",
    )

    @Argument(help: "Paths to scan (directories or files)")
    var paths: [String] = ["."]

    @OptionGroup(title: "Embedding") var embedding: EmbeddingOptions

    @Option(
        name: .customLong("group-by"),
        help:
            "Last N dirname segments to group by (1 = parent dir, 2 = parent+grandparent, etc.)",
    )
    var groupBy: Int = 2

    @Option(name: .shortAndLong, help: "Output format (text, json, xcode)")
    var format: OutputFormat = .text

    func run() async throws {
        let ctx = try await embedding.loadScanContext(paths: paths)
        guard ctx.snippets.count >= 4 else {
            print("Not enough snippets (\(ctx.snippets.count)) for cohesion analysis")
            return
        }

        // Group snippets by the last `groupBy` dirname segments.
        var module: [Int: String] = [:]
        for (i, snippet) in ctx.snippets.enumerated() {
            let parts = snippet.file.split(separator: "/")
            let dirParts = parts.dropLast()
            let tail = dirParts.suffix(groupBy)
            module[i] = tail.isEmpty ? "<unknown>" : String(tail.joined(separator: "/"))
        }
        var byModule: [String: [Int]] = [:]
        for (i, m) in module { byModule[m, default: []].append(i) }
        guard byModule.count >= 2 else {
            print("Only \(byModule.count) module(s) discovered; need ≥2 for inter-module signal")
            return
        }

        struct Row: Encodable {
            let module: String
            let snippets: Int
            let intra: Float
            let inter: Float
            let cohesion: Float
        }
        var rows: [Row] = []
        for (mod, indices) in byModule where indices.count >= 2 {
            var intraSum: Float = 0
            var intraCount = 0
            for i in indices {
                for j in indices where j > i {
                    intraSum += SearchMath.cosine(
                        ctx.normalizedVectors[i], ctx.normalizedVectors[j])
                    intraCount += 1
                }
            }
            let intra = intraCount > 0 ? intraSum / Float(intraCount) : 0
            var interSum: Float = 0
            var interCount = 0
            let indexSet = Set(indices)
            for i in indices {
                for j in 0..<ctx.snippets.count where !indexSet.contains(j) {
                    interSum += SearchMath.cosine(
                        ctx.normalizedVectors[i], ctx.normalizedVectors[j])
                    interCount += 1
                }
            }
            let inter = interCount > 0 ? interSum / Float(interCount) : 0
            rows.append(
                Row(
                    module: mod, snippets: indices.count, intra: intra, inter: inter,
                    cohesion: intra - inter))
        }
        rows.sort { $0.cohesion > $1.cohesion }

        switch format {
        case .text:
            print("Cohesion per module (intra-mod − inter-mod cosine):")
            print()
            let header =
                "module".padded(40) + "  " + "n".padded(6, alignRight: true)
                + "  " + "intra".padded(7, alignRight: true)
                + "  " + "inter".padded(7, alignRight: true)
                + "  " + "cohesion".padded(9, alignRight: true)
            print(header)
            print(String(repeating: "─", count: header.count))
            for row in rows {
                let intraPct = Int((row.intra * 100).rounded())
                let interPct = Int((row.inter * 100).rounded())
                let cohesionPct = Int((row.cohesion * 100).rounded())
                let signed = row.cohesion > 0 ? "+\(cohesionPct)%" : "\(cohesionPct)%"
                let line =
                    row.module.padded(40) + "  "
                    + "\(row.snippets)".padded(6, alignRight: true) + "  "
                    + "\(intraPct)%".padded(7, alignRight: true) + "  "
                    + "\(interPct)%".padded(7, alignRight: true) + "  "
                    + signed.padded(9, alignRight: true)
                print(line)
            }
            print()
            print(
                "Higher = module snippets resemble each other more than the rest. "
                    + "Negative = split candidate.")
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

// MARK: - Shared helpers

extension String {
    /// Pad with spaces to `width`. ASCII-width only.
    func padded(_ width: Int, alignRight: Bool = false) -> String {
        if self.count >= width { return self }
        let padding = String(repeating: " ", count: width - self.count)
        return alignRight ? padding + self : self + padding
    }
}

/// L2-normalization + cosine helpers used by every embedding subcommand.
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
