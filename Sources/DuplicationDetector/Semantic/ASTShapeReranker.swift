//  ASTShapeReranker.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - ASTShapeReranker

/// AST-shape similarity reranker for semantic clone candidates.
///
/// The MaxSim reranker (`MaxSimVerifier`) addresses cosine's positional
/// blindness by going token-by-token in the embedding space. The shape
/// reranker addresses a different blind spot: **structural** divergence
/// — two snippets with the same identifiers but completely different
/// syntactic skeletons (e.g. one is a guard chain, the other is a
/// switch) get high cosine because they share vocabulary, but they
/// shouldn't be reported as Type-2 clones.
///
/// Approach: parse each snippet with SwiftSyntax, walk the tree
/// pre-order, emit the type-name of each node. The result is a linear
/// sequence of syntax categories like `["FunctionDecl",
/// "FunctionSignature", "ParameterClause", "Parameter", "CodeBlock",
/// ...]`. Two snippets' shape sequences are compared by **trigram
/// Jaccard**: extract all consecutive 3-grams, set-intersect.
///
/// Why trigrams over 1-grams: a 1-gram comparison rewards two snippets
/// that use the same set of syntax nodes without caring about order.
/// Trigrams require local order to agree — `(FunctionDecl, FunctionSignature,
/// ParameterClause)` matches only against the same triple, not against
/// any reshuffling.
///
/// Why not full APTED tree edit distance: APTED is the gold standard,
/// but ~500 LOC of fairly intricate Swift to implement correctly. The
/// trigram approximation is empirically strong on Type-2 detection at
/// a fraction of the implementation cost; we can upgrade to full APTED
/// later if the precision ceiling needs to be raised.
public struct ASTShapeReranker: Sendable {
    public init() {}

    /// Compute symmetric Jaccard over the trigrams of each snippet's
    /// linearized AST node-type sequence. Returns `0` when either
    /// snippet fails to parse or produces fewer than 3 nodes.
    public func score(_ a: String, _ b: String) -> Double {
        let trigramsA = trigrams(of: nodeTypeSequence(a))
        let trigramsB = trigrams(of: nodeTypeSequence(b))
        if trigramsA.isEmpty, trigramsB.isEmpty { return 0 }
        let intersection = Double(trigramsA.intersection(trigramsB).count)
        let union = Double(trigramsA.union(trigramsB).count)
        return union == 0 ? 0 : intersection / union
    }

    /// Pre-order walk of the SwiftSyntax tree, emitting one
    /// type-name string per visited node.
    private func nodeTypeSequence(_ source: String) -> [String] {
        let tree = Parser.parse(source: source)
        let visitor = ShapeVisitor()
        visitor.walk(tree)
        return visitor.types
    }

    /// Build all consecutive 3-grams of the sequence as a `Set<String>`
    /// of `"A|B|C"` keys.
    private func trigrams(of seq: [String]) -> Set<String> {
        guard seq.count >= 3 else { return [] }
        var out: Set<String> = []
        out.reserveCapacity(seq.count - 2)
        for i in 0..<(seq.count - 2) {
            out.insert("\(seq[i])|\(seq[i + 1])|\(seq[i + 2])")
        }
        return out
    }
}

// MARK: - ShapeVisitor

/// Records each visited syntax node's runtime type name. Pre-order
/// because that's the canonical linearization (parent before children,
/// children left-to-right) — matches how a reader perceives the tree.
private final class ShapeVisitor: SyntaxAnyVisitor {
    var types: [String] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        let raw = String(reflecting: node.syntaxNodeType)
        // Strip module prefix ("SwiftSyntax.FunctionDeclSyntax" →
        // "FunctionDeclSyntax") so noise/version-drift in the reflected
        // name doesn't move the comparison.
        if let dotIndex = raw.lastIndex(of: ".") {
            types.append(String(raw[raw.index(after: dotIndex)...]))
        } else {
            types.append(raw)
        }
        return .visitChildren
    }
}
