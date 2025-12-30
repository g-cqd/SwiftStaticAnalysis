//
//  SemanticCloneDetector.swift
//  SwiftStaticAnalysis
//
//  Detects semantic clones (Type 3 clones) using AST structural comparison.
//

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - Semantic Clone Detector

/// Detects semantic clones using AST fingerprinting.
public struct SemanticCloneDetector: Sendable {
    // MARK: Lifecycle

    public init(
        minimumNodes: Int = 10,
        minimumSimilarity: Double = 0.7,
        normalizeResultBuilders: Bool = true,
    ) {
        self.minimumNodes = minimumNodes
        self.minimumSimilarity = minimumSimilarity
        self.normalizeResultBuilders = normalizeResultBuilders
        parser = SwiftFileParser()
    }

    // MARK: Public

    /// Minimum number of AST nodes to consider.
    public let minimumNodes: Int

    /// Minimum similarity threshold (0.0 to 1.0).
    public let minimumSimilarity: Double

    /// Whether to normalize result builder closures (SwiftUI views).
    public let normalizeResultBuilders: Bool

    /// Detect semantic clones from pre-collected fingerprinted nodes.
    ///
    /// - Parameter nodes: Array of fingerprinted nodes.
    /// - Returns: Array of clone groups found.
    public func detect(in nodes: [FingerprintedNode]) -> [CloneGroup] {
        let hashGroups = groupByFingerprint(nodes)
        return buildCloneGroups(from: hashGroups)
    }

    /// Detect semantic clones in the given files.
    public func detect(in files: [String]) async throws -> [CloneGroup] {
        // Collect all fingerprinted nodes from all files
        var allNodes: [FingerprintedNode] = []

        for file in files {
            let tree = try await parser.parse(file)
            let visitor = ASTFingerprintVisitor(
                file: file,
                tree: tree,
                minimumNodes: minimumNodes,
                normalizeResultBuilders: normalizeResultBuilders,
            )
            visitor.walk(tree)
            allNodes.append(contentsOf: visitor.fingerprintedNodes)
        }

        let hashGroups = groupByFingerprint(allNodes)
        return buildCloneGroups(from: hashGroups)
    }

    // MARK: Private

    /// The file parser.
    private let parser: SwiftFileParser

    /// Group nodes by their fingerprint hash.
    private func groupByFingerprint(_ nodes: [FingerprintedNode]) -> [UInt64: [FingerprintedNode]] {
        var hashGroups: [UInt64: [FingerprintedNode]] = [:]
        for node in nodes {
            hashGroups[node.fingerprint.hash, default: []].append(node)
        }
        return hashGroups
    }

    /// Build clone groups from hash-grouped fingerprinted nodes.
    private func buildCloneGroups(from hashGroups: [UInt64: [FingerprintedNode]]) -> [CloneGroup] {
        var cloneGroups: [CloneGroup] = []

        for (hash, groupNodes) in hashGroups where groupNodes.count >= 2 {
            let verified = verifySemanticClones(groupNodes)

            for group in verified {
                let clones = group.map { node in
                    Clone(
                        file: node.file,
                        startLine: node.startLine,
                        endLine: node.endLine,
                        tokenCount: node.tokenCount,
                        codeSnippet: "",
                    )
                }

                if clones.count >= 2 {
                    let similarity = calculateSimilarity(group)

                    if similarity >= minimumSimilarity {
                        cloneGroups.append(
                            CloneGroup(
                                type: .semantic,
                                clones: clones,
                                similarity: similarity,
                                fingerprint: String(hash),
                            ))
                    }
                }
            }
        }

        return cloneGroups.deduplicated()
    }

    /// Verify fingerprint matches are actual semantic clones.
    private func verifySemanticClones(_ nodes: [FingerprintedNode]) -> [[FingerprintedNode]] {
        var groups: [[FingerprintedNode]] = []
        var used = Set<Int>()

        for (i, node1) in nodes.enumerated() {
            guard !used.contains(i) else { continue }

            var group = [node1]
            used.insert(i)

            for (j, node2) in nodes.enumerated() where j > i && !used.contains(j) {
                // Skip if same file and overlapping lines
                if node1.file == node2.file {
                    let overlaps = !(node1.endLine < node2.startLine || node2.endLine < node1.startLine)
                    if overlaps {
                        continue
                    }
                }

                // Compare fingerprints
                if fingerprintsMatch(node1.fingerprint, node2.fingerprint) {
                    group.append(node2)
                    used.insert(j)
                }
            }

            if group.count >= 2 {
                groups.append(group)
            }
        }

        return groups
    }

    /// Check if two fingerprints are similar enough.
    private func fingerprintsMatch(_ fp1: ASTFingerprint, _ fp2: ASTFingerprint) -> Bool {
        // Must have same hash (structure)
        guard fp1.hash == fp2.hash else { return false }

        // Must have same root kind
        guard fp1.rootKind == fp2.rootKind else { return false }

        // Allow some variance in node count (within 20%)
        let maxCount = max(fp1.nodeCount, fp2.nodeCount)
        let minCount = min(fp1.nodeCount, fp2.nodeCount)
        let countRatio = Double(minCount) / Double(maxCount)

        return countRatio >= 0.8
    }

    /// Calculate similarity between a group of nodes.
    private func calculateSimilarity(_ group: [FingerprintedNode]) -> Double {
        guard group.count >= 2 else { return 0 }

        // Use fingerprint similarity
        var totalSimilarity = 0.0
        var comparisons = 0

        for i in 0..<group.count {
            for j in (i + 1)..<group.count {
                let sim = fingerprintSimilarity(group[i].fingerprint, group[j].fingerprint)
                totalSimilarity += sim
                comparisons += 1
            }
        }

        return comparisons > 0 ? totalSimilarity / Double(comparisons) : 0
    }

    /// Calculate similarity between two fingerprints.
    private func fingerprintSimilarity(_ fp1: ASTFingerprint, _ fp2: ASTFingerprint) -> Double {
        // Same hash means identical structure
        if fp1.hash == fp2.hash {
            // Calculate node count similarity
            let maxCount = max(fp1.nodeCount, fp2.nodeCount)
            let minCount = min(fp1.nodeCount, fp2.nodeCount)
            return Double(minCount) / Double(maxCount)
        }

        return 0
    }
}
