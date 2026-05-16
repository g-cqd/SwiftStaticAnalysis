//  PDGReranker.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore

// MARK: - PDGReranker

/// Program-dependence-graph similarity reranker for semantic clone
/// candidates. Slots into the embedding-discovery rerank chain
/// alongside `MaxSimVerifier`, `ASTShapeReranker`, and `APTEDReranker`.
///
/// The AST-shape reranker catches structural divergence at the syntax
/// level; APTED quantifies edit distance over the syntax tree. Both
/// operate on `SwiftSyntax`. The PDG reranker operates one layer
/// deeper, on `swiftc -emit-sil`-derived program-dependence graphs.
/// That captures *data-flow* equivalence — two snippets with different
/// syntactic shape but identical SSA def-use topology should score
/// high; two snippets with similar syntax but different data-flow
/// (e.g. swapped operands, different mutation sites) should score low.
///
/// ## Approach
///
/// 1. Write each snippet to a temporary `.swift` file.
/// 2. Invoke `swiftc -emit-sil` via `SILExtractor`.
/// 3. Parse SIL into `SILFunction` then build `ProgramDependenceGraph`
///    per function.
/// 4. Compute a per-function fingerprint multiset: each PDG edge
///    contributes a tuple `(sourceKind, targetKind, edgeKind)` and
///    each node contributes its `(kind, inDegree, outDegree)`.
/// 5. Score by Jaccard over the per-snippet union of all functions'
///    fingerprints.
///
/// ## Failure mode
///
/// Snippets that don't compile standalone (mid-function fragments,
/// references to undeclared types) return **`1.0`** so the rerank
/// gate falls open instead of dropping the candidate. This mirrors
/// `MaxSimVerifier`'s "skip the gate on provider failure" pattern.
public struct PDGReranker: Sendable {
    public init(
        swiftcPath: String = "/usr/bin/swiftc",
        extraSwiftcArgs: [String] = []
    ) {
        self.swiftcPath = swiftcPath
        self.extraSwiftcArgs = extraSwiftcArgs
    }

    /// Compute symmetric Jaccard over PDG fingerprints of each snippet.
    /// Returns `1.0` when either snippet fails to emit SIL (so the
    /// rerank gate doesn't penalise uncompilable fragments).
    public func score(_ a: String, _ b: String) -> Double {
        let fingerprintA = fingerprint(of: a)
        let fingerprintB = fingerprint(of: b)
        guard let fingerprintA, let fingerprintB else { return 1.0 }
        if fingerprintA.isEmpty, fingerprintB.isEmpty { return 0 }
        let intersection = Double(fingerprintA.intersection(fingerprintB).count)
        let union = Double(fingerprintA.union(fingerprintB).count)
        return union == 0 ? 0 : intersection / union
    }

    // MARK: Private

    private let swiftcPath: String
    private let extraSwiftcArgs: [String]

    /// Build the PDG fingerprint for `source`. Returns `nil` when
    /// SIL extraction fails (uncompilable snippet); empty set when
    /// extraction succeeds but produces no functions (e.g. a file
    /// of imports only).
    private func fingerprint(of source: String) -> Set<String>? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa-pdg-\(UUID().uuidString).swift")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let functions: [SILFunction]
        do {
            functions = try SILExtractor.extract(
                from: url.path,
                swiftcPath: swiftcPath,
                extraArguments: extraSwiftcArgs
            )
        } catch {
            return nil
        }

        var tokens: Set<String> = []
        for function in functions {
            let pdg = ProgramDependenceGraph.build(from: function)
            ingestFingerprint(of: pdg, into: &tokens)
        }
        return tokens
    }

    /// Emit fingerprint tokens for every node and edge in `pdg`. Each
    /// edge becomes one `e:<srcKind>|<tgtKind>|<edgeKind>` token; each
    /// SSA value used as a def becomes `n:<inDeg>|<outDeg>` so two
    /// graphs with identical topology produce identical multisets.
    private func ingestFingerprint(
        of pdg: ProgramDependenceGraph,
        into tokens: inout Set<String>
    ) {
        var inDegree: [String: Int] = [:]
        var outDegree: [String: Int] = [:]
        for edge in pdg.edges {
            let src = key(for: edge.source)
            let tgt = key(for: edge.target)
            let kind = String(describing: edge.kind)
            tokens.insert("e:\(src)|\(tgt)|\(kind)")
            outDegree[src, default: 0] += 1
            inDegree[tgt, default: 0] += 1
        }
        // Per-node degree fingerprint. Sorted iteration keeps the
        // sequence stable across runs.
        for nodeKey in Set(inDegree.keys).union(outDegree.keys).sorted() {
            let inD = inDegree[nodeKey] ?? 0
            let outD = outDegree[nodeKey] ?? 0
            tokens.insert("n:\(inD)|\(outD)")
        }
    }

    /// Stable string key for a PDG node — collapses concrete SSA
    /// value names so two structurally-identical graphs with different
    /// register allocations produce matching tokens.
    private func key(for node: PDGNodeKind) -> String {
        switch node {
        case .value:
            return "v"
        case .block:
            return "b"
        }
    }
}
