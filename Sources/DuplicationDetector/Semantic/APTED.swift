//  APTED.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - APTEDTree

/// Post-order-indexed tree for APTED tree edit distance.
///
/// Stores nodes flat in post-order. For each node we precompute the
/// leftmost-leaf-descendant index and the post-order index of the
/// parent. The label is a `String` (SwiftSyntax node type-name in the
/// reranker bridge); the cost model treats label equality as zero-cost
/// rename and inequality as unit-cost rename.
///
/// The data layout matches Zhang-Shasha 1989 / Pawlik-Augsten 2015 —
/// post-order indexing simplifies the keyroots computation and lets the
/// DP recurrence reference `forestdist[i][j]` as a direct subproblem.
public struct APTEDTree: Sendable {
    /// Node labels in post-order (`labels[i]` is the `i`th node visited
    /// post-order, root last).
    public let labels: [String]
    /// `leftLeaf[i]` = post-order index of the leftmost-leaf descendant
    /// of node `i`. For a leaf, `leftLeaf[i] == i`.
    public let leftLeaf: [Int]
    /// `parent[i]` = post-order index of parent, or `-1` for the root.
    public let parent: [Int]

    public var size: Int { labels.count }

    /// Keyroots of the tree — the nodes that act as roots for the
    /// outer loop of Zhang-Shasha. Defined as the root plus every node
    /// whose `leftLeaf` differs from its parent's `leftLeaf`. In other
    /// words: any node whose subtree's leftmost leaf is distinct from
    /// the parent's leftmost leaf. The keyroots set has size O(leaves),
    /// not O(nodes) — the source of the algorithm's efficiency.
    public func keyroots() -> [Int] {
        var seen: [Int: Int] = [:]  // leftLeaf -> latest postorder
        for i in 0..<size {
            seen[leftLeaf[i]] = i
        }
        return seen.values.sorted()
    }
}

// MARK: - APTED algorithm

/// Tree edit distance via Zhang-Shasha (1989), which is the LEFT-path
/// strategy of the APTED framework (Pawlik & Augsten 2015).
///
/// The 2015 APTED paper adds a strategy-selection layer on top that
/// picks LEFT, RIGHT, or HEAVY paths per (subtree, subtree) pair to
/// minimize worst-case operations. The asymptotic improvement is
/// O(n³) for APTED vs O(n²·d·l) for Zhang-Shasha (d=depth, l=leaves).
/// On the balanced Swift function bodies this reranker operates on
/// (typically n=50-150, d=5-10), Zhang-Shasha is sub-millisecond per
/// pair — the strategy layer is unnecessary at our scale. Documented
/// as a future direction in case heavily-skewed inputs surface.
public enum APTED {
    /// Compute the tree edit distance between two trees. Returns the
    /// number of insert+delete+rename operations to transform `a` into
    /// `b`. Cost model: insert = delete = 1; rename = 0 if labels are
    /// equal, 1 otherwise.
    public static func distance(_ a: APTEDTree, _ b: APTEDTree) -> Double {
        if a.size == 0, b.size == 0 { return 0 }
        if a.size == 0 { return Double(b.size) }
        if b.size == 0 { return Double(a.size) }

        // treedist[i][j] = TED(subtree rooted at a.labels[i],
        //                       subtree rooted at b.labels[j]).
        var treedist = Array(
            repeating: Array(repeating: 0.0, count: b.size),
            count: a.size
        )

        for i in a.keyroots() {
            for j in b.keyroots() {
                treeEditDistance(
                    i: i, j: j, a: a, b: b, treedist: &treedist)
            }
        }

        return treedist[a.size - 1][b.size - 1]
    }

    /// Inner DP for one (keyroot_a, keyroot_b) pair. Fills
    /// `treedist[i'][j']` for every `(i', j')` in the post-order
    /// rectangle bounded by the keyroots' leftLeaf indices.
    private static func treeEditDistance(
        i: Int,
        j: Int,
        a: APTEDTree,
        b: APTEDTree,
        treedist: inout [[Double]]
    ) {
        let li = a.leftLeaf[i]
        let lj = b.leftLeaf[j]
        let m = i - li + 2  // rows: from li-1 (empty prefix) to i, inclusive
        let n = j - lj + 2  // cols: from lj-1 (empty prefix) to j, inclusive

        // forestdist[x][y] = TED(forest from li..(li+x-1), forest from lj..(lj+y-1))
        var forestdist = Array(
            repeating: Array(repeating: 0.0, count: n),
            count: m
        )

        // Base row + column: pure delete / insert sequences.
        for x in 1..<m {
            forestdist[x][0] = forestdist[x - 1][0] + 1  // delete cost
        }
        for y in 1..<n {
            forestdist[0][y] = forestdist[0][y - 1] + 1  // insert cost
        }

        // Fill the rectangle.
        for x in 1..<m {
            let ai = li + x - 1
            for y in 1..<n {
                let bj = lj + y - 1
                if a.leftLeaf[ai] == li && b.leftLeaf[bj] == lj {
                    // Both subtrees end at the keyroot's leftmost-leaf —
                    // this is a node-pair case. Three operations:
                    let renameCost = a.labels[ai] == b.labels[bj] ? 0.0 : 1.0
                    forestdist[x][y] = min(
                        forestdist[x - 1][y] + 1,  // delete from a
                        forestdist[x][y - 1] + 1,  // insert into a
                        forestdist[x - 1][y - 1] + renameCost
                    )
                    treedist[ai][bj] = forestdist[x][y]
                } else {
                    // Otherwise we're in the forest-recurrence case:
                    // recurse into already-computed subtree distances.
                    let leftX = a.leftLeaf[ai] - li  // post-order offset
                    let leftY = b.leftLeaf[bj] - lj
                    forestdist[x][y] = min(
                        forestdist[x - 1][y] + 1,
                        forestdist[x][y - 1] + 1,
                        forestdist[leftX][leftY] + treedist[ai][bj]
                    )
                }
            }
        }
    }
}

// MARK: - APTEDReranker

/// AST tree-edit-distance reranker for embedding-discovered clone
/// candidates.
///
/// Stronger structural-similarity signal than `ASTShapeReranker`'s
/// trigram Jaccard — trigrams agree on local order but ignore global
/// reordering; APTED captures any structural transformation as a
/// minimum sequence of insert/delete/rename ops. Bigger lever, bigger
/// implementation, slower per-pair.
///
/// Normalization: returns `1 - (TED / max(|treeA|, |treeB|))` clamped
/// to `[0, 1]`. Score = 1 → identical trees; score = 0 → maximally
/// different. The `--embedding-shape-threshold` semantics carry over.
public struct APTEDReranker: Sendable {
    public init() {}

    public func score(_ a: String, _ b: String) -> Double {
        let treeA = APTEDTree.fromSwiftSource(a)
        let treeB = APTEDTree.fromSwiftSource(b)
        guard treeA.size > 0, treeB.size > 0 else { return 0 }
        let ted = APTED.distance(treeA, treeB)
        let largerTree = Double(max(treeA.size, treeB.size))
        let normalized = 1.0 - ted / largerTree
        return max(0.0, min(1.0, normalized))
    }
}

// MARK: - SwiftSyntax bridge

extension APTEDTree {
    /// Parse Swift source and lower it into an APTED tree.
    /// Node label = SwiftSyntax node type-name with module prefix stripped.
    /// Skips trivia and `TokenSyntax` — only structural syntax nodes
    /// participate, matching the `ASTShapeReranker` convention.
    public static func fromSwiftSource(_ source: String) -> APTEDTree {
        let tree = Parser.parse(source: source)
        var labels: [String] = []
        var leftLeaf: [Int] = []
        var parent: [Int] = []

        // Pre-order DFS to a temporary representation, then renumber
        // into post-order. Track structural nodes only (skip tokens).
        var dfsNodes: [DFSNodeImpl] = []
        let rootIdx = collectStructural(node: Syntax(tree), parent: -1, into: &dfsNodes)
        guard rootIdx >= 0 else { return APTEDTree(labels: [], leftLeaf: [], parent: []) }

        // Compute post-order via iterative DFS.
        var postOrder: [Int] = []
        postOrder.reserveCapacity(dfsNodes.count)
        var stack: [(Int, Int)] = [(rootIdx, 0)]  // (dfsIndex, childCursor)
        while let (cur, cursor) = stack.last {
            let node = dfsNodes[cur]
            if cursor < node.children.count {
                stack[stack.count - 1] = (cur, cursor + 1)
                stack.append((node.children[cursor], 0))
            } else {
                postOrder.append(cur)
                stack.removeLast()
            }
        }

        // Map DFS index → post-order index.
        var dfsToPost = [Int](repeating: -1, count: dfsNodes.count)
        for (postIdx, dfsIdx) in postOrder.enumerated() {
            dfsToPost[dfsIdx] = postIdx
        }

        labels.reserveCapacity(postOrder.count)
        parent.reserveCapacity(postOrder.count)
        leftLeaf.reserveCapacity(postOrder.count)
        for dfsIdx in postOrder {
            let node = dfsNodes[dfsIdx]
            labels.append(node.label)
            parent.append(node.parent >= 0 ? dfsToPost[node.parent] : -1)
        }

        // leftLeaf[i] for each post-order index. For a leaf, it's i
        // itself. For an internal node, it's the leftLeaf of its
        // leftmost child (which, in post-order, is the FIRST child in
        // DFS order = the smallest post-order index among children).
        for postIdx in 0..<postOrder.count {
            let dfsIdx = postOrder[postIdx]
            let children = dfsNodes[dfsIdx].children
            if children.isEmpty {
                leftLeaf.append(postIdx)
            } else {
                let leftmostChildDFS = children[0]
                let leftmostChildPost = dfsToPost[leftmostChildDFS]
                leftLeaf.append(leftLeaf[leftmostChildPost])
            }
        }

        return APTEDTree(labels: labels, leftLeaf: leftLeaf, parent: parent)
    }

}

extension APTEDTree {
    /// Internal flat-node form used during the pre-order pass before
    /// renumbering into post-order.
    fileprivate struct DFSNodeImpl {
        let label: String
        var children: [Int]
        var parent: Int
    }

    fileprivate static func collectStructural(
        node: Syntax,
        parent: Int,
        into nodes: inout [DFSNodeImpl]
    ) -> Int {
        // Skip TokenSyntax — they're leaves but pure surface form, and
        // matching them inflates trees with little structural signal.
        if node.is(TokenSyntax.self) { return -1 }

        let raw = String(reflecting: node.syntaxNodeType)
        let label: String
        if let dotIndex = raw.lastIndex(of: ".") {
            label = String(raw[raw.index(after: dotIndex)...])
        } else {
            label = raw
        }

        let myIndex = nodes.count
        nodes.append(DFSNodeImpl(label: label, children: [], parent: parent))

        for child in node.children(viewMode: .sourceAccurate) {
            let childIdx = collectStructural(
                node: Syntax(child), parent: myIndex, into: &nodes
            )
            if childIdx >= 0 {
                nodes[myIndex].children.append(childIdx)
            }
        }
        return myIndex
    }
}
