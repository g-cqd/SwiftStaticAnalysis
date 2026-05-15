//  APTEDTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import DuplicationDetector

@Suite("APTED Tree Edit Distance")
struct APTEDTests {
    // Manual tree-building helper: build from postorder triples
    // (label, leftLeaf, parent).
    private func tree(_ entries: [(label: String, leftLeaf: Int, parent: Int)]) -> APTEDTree {
        APTEDTree(
            labels: entries.map(\.label),
            leftLeaf: entries.map(\.leftLeaf),
            parent: entries.map(\.parent)
        )
    }

    @Test("Two empty trees have distance 0")
    func emptyTrees() {
        let a = APTEDTree(labels: [], leftLeaf: [], parent: [])
        let b = APTEDTree(labels: [], leftLeaf: [], parent: [])
        #expect(APTED.distance(a, b) == 0)
    }

    @Test("Single-node tree against empty has distance equal to its size")
    func emptyVsSingle() {
        let a = APTEDTree(labels: ["A"], leftLeaf: [0], parent: [-1])
        let b = APTEDTree(labels: [], leftLeaf: [], parent: [])
        #expect(APTED.distance(a, b) == 1)
        #expect(APTED.distance(b, a) == 1)
    }

    @Test("Two identical single-node trees have distance 0")
    func identicalLeaf() {
        let a = APTEDTree(labels: ["X"], leftLeaf: [0], parent: [-1])
        let b = APTEDTree(labels: ["X"], leftLeaf: [0], parent: [-1])
        #expect(APTED.distance(a, b) == 0)
    }

    @Test("Two single-node trees with different labels have distance 1")
    func renamedLeaf() {
        let a = APTEDTree(labels: ["X"], leftLeaf: [0], parent: [-1])
        let b = APTEDTree(labels: ["Y"], leftLeaf: [0], parent: [-1])
        #expect(APTED.distance(a, b) == 1)
    }

    @Test("Identical 3-node trees (root + 2 leaf children) have distance 0")
    func identicalSmallTree() {
        // Tree shape:   R
        //              / \
        //             A   B    (postorder: A=0, B=1, R=2)
        let a = tree([
            (label: "A", leftLeaf: 0, parent: 2),
            (label: "B", leftLeaf: 1, parent: 2),
            (label: "R", leftLeaf: 0, parent: -1),
        ])
        let b = tree([
            (label: "A", leftLeaf: 0, parent: 2),
            (label: "B", leftLeaf: 1, parent: 2),
            (label: "R", leftLeaf: 0, parent: -1),
        ])
        #expect(APTED.distance(a, b) == 0)
    }

    @Test("Replacing one leaf changes distance by 1")
    func smallTreeWithOneRename() {
        let a = tree([
            (label: "A", leftLeaf: 0, parent: 2),
            (label: "B", leftLeaf: 1, parent: 2),
            (label: "R", leftLeaf: 0, parent: -1),
        ])
        let b = tree([
            (label: "A", leftLeaf: 0, parent: 2),
            (label: "C", leftLeaf: 1, parent: 2),
            (label: "R", leftLeaf: 0, parent: -1),
        ])
        #expect(APTED.distance(a, b) == 1)
    }

    @Test("Tree edit distance is symmetric")
    func symmetric() {
        let a = tree([
            (label: "A", leftLeaf: 0, parent: 1),
            (label: "B", leftLeaf: 0, parent: -1),
        ])
        let b = tree([
            (label: "X", leftLeaf: 0, parent: 2),
            (label: "Y", leftLeaf: 1, parent: 2),
            (label: "Z", leftLeaf: 0, parent: -1),
        ])
        #expect(APTED.distance(a, b) == APTED.distance(b, a))
    }
}

@Suite("APTED Reranker (Swift source bridge)")
struct APTEDRerankerTests {
    @Test("Same source yields score 1")
    func identicalSwiftSource() {
        let reranker = APTEDReranker()
        let src = "func add(_ a: Int, _ b: Int) -> Int { return a + b }"
        let score = reranker.score(src, src)
        #expect(score == 1.0)
    }

    @Test("Type-2 clone (renamed identifiers, same shape) scores higher than unrelated")
    func typeTwoCloneVsUnrelated() {
        let reranker = APTEDReranker()
        let sumA = "func computeSum(nums: [Int]) -> Int { var t = 0; for n in nums { t += n }; return t }"
        let sumB = "func addValues(vals: [Int]) -> Int { var s = 0; for v in vals { s += v }; return s }"
        let unrelated = "actor Counter { var c = 0; func bump() async { c += 1 } }"

        let clonePairScore = reranker.score(sumA, sumB)
        let unrelatedScore = reranker.score(sumA, unrelated)
        #expect(
            clonePairScore > unrelatedScore,
            "Type-2 clone (sumA vs sumB) should score higher than unrelated (sumA vs Counter actor); got clone=\(clonePairScore), unrelated=\(unrelatedScore)"
        )
        #expect(clonePairScore > 0.5)
    }
}
