//
//  ASTFingerprintVisitor.swift
//  SwiftStaticAnalysis
//
//  Creates structural fingerprints of AST subtrees for semantic clone detection.
//

import Foundation
import SwiftStaticAnalysisCore
import SwiftSyntax

// MARK: - ASTFingerprint

/// A structural fingerprint of an AST subtree.
public struct ASTFingerprint: Sendable, Hashable {
    // MARK: Lifecycle

    public init(hash: UInt64, depth: Int, nodeCount: Int, rootKind: String) {
        self.hash = hash
        self.depth = depth
        self.nodeCount = nodeCount
        self.rootKind = rootKind
    }

    // MARK: Public

    /// The hash of the structure.
    public let hash: UInt64

    /// The depth of the subtree.
    public let depth: Int

    /// Number of nodes in the subtree.
    public let nodeCount: Int

    /// The syntax kind at the root.
    public let rootKind: String
}

// MARK: - FingerprintedNode

/// An AST node with its fingerprint and location.
public struct FingerprintedNode: Sendable {
    // MARK: Lifecycle

    public init(
        file: String,
        fingerprint: ASTFingerprint,
        startLine: Int,
        endLine: Int,
        startColumn: Int,
        tokenCount: Int,
    ) {
        self.file = file
        self.fingerprint = fingerprint
        self.startLine = startLine
        self.endLine = endLine
        self.startColumn = startColumn
        self.tokenCount = tokenCount
    }

    // MARK: Public

    /// The file containing this node.
    public let file: String

    /// The fingerprint.
    public let fingerprint: ASTFingerprint

    /// Start line.
    public let startLine: Int

    /// End line.
    public let endLine: Int

    /// Start column.
    public let startColumn: Int

    /// Token count (approximate).
    public let tokenCount: Int
}

// MARK: - ASTFingerprintVisitor

/// Computes structural fingerprints for function and closure bodies.
public final class ASTFingerprintVisitor: SyntaxVisitor {
    // MARK: Lifecycle

    public init(
        file: String,
        tree: SourceFileSyntax,
        minimumNodes: Int = 10,
        normalizeResultBuilders: Bool = true,
    ) {
        self.file = file
        converter = SourceLocationConverter(fileName: file, tree: tree)
        self.minimumNodes = minimumNodes
        self.normalizeResultBuilders = normalizeResultBuilders
        resultBuilderAnalyzer = normalizeResultBuilders ? ResultBuilderAnalyzer() : nil
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Public

    /// Collected fingerprinted nodes.
    public private(set) var fingerprintedNodes: [FingerprintedNode] = []

    /// Whether to normalize result builder closures.
    public let normalizeResultBuilders: Bool

    // MARK: - Function Declarations

    override public func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            fingerprintCodeBlock(body)
        }
        return .visitChildren
    }

    // MARK: - Closure Expressions

    override public func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        fingerprintClosure(node)
        return .visitChildren
    }

    // MARK: - Initializers

    override public func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            fingerprintCodeBlock(body)
        }
        return .visitChildren
    }

    // MARK: - Accessors (computed properties, subscripts)

    override public func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            fingerprintCodeBlock(body)
        }
        return .visitChildren
    }

    // MARK: Private

    /// Source location converter.
    private let converter: SourceLocationConverter

    /// File path.
    private let file: String

    /// Minimum nodes to consider.
    private let minimumNodes: Int

    /// Result builder analyzer for normalizing SwiftUI views.
    private let resultBuilderAnalyzer: ResultBuilderAnalyzer?

    // MARK: - Fingerprinting

    private func fingerprintCodeBlock(_ block: CodeBlockSyntax) {
        let result = computeFingerprint(for: Syntax(block))

        guard result.nodeCount >= minimumNodes else { return }

        let startLoc = converter.location(for: block.positionAfterSkippingLeadingTrivia)
        let endLoc = converter.location(for: block.endPositionBeforeTrailingTrivia)

        fingerprintedNodes.append(
            FingerprintedNode(
                file: file,
                fingerprint: result,
                startLine: startLoc.line,
                endLine: endLoc.line,
                startColumn: startLoc.column,
                tokenCount: countTokens(in: block),
            ))
    }

    private func fingerprintClosure(_ closure: ClosureExprSyntax) {
        // Check if this is a result builder closure and compute appropriate fingerprint
        let result: ASTFingerprint =
            if let analyzer = resultBuilderAnalyzer,
                let normalized = analyzer.normalizeClosure(closure)
            {
                // Use normalized fingerprint for result builder closures
                computeNormalizedFingerprint(for: normalized)
            } else {
                computeFingerprint(for: Syntax(closure))
            }

        guard result.nodeCount >= minimumNodes else { return }

        let startLoc = converter.location(for: closure.positionAfterSkippingLeadingTrivia)
        let endLoc = converter.location(for: closure.endPositionBeforeTrailingTrivia)

        fingerprintedNodes.append(
            FingerprintedNode(
                file: file,
                fingerprint: result,
                startLine: startLoc.line,
                endLine: endLoc.line,
                startColumn: startLoc.column,
                tokenCount: countTokens(in: closure),
            ))
    }

    /// Compute fingerprint for a normalized result builder closure.
    private func computeNormalizedFingerprint(for normalized: NormalizedResultBuilderClosure) -> ASTFingerprint {
        var hasher = FingerprintHasher()

        // Hash the normalized structure instead of raw AST
        var nodeCount = 0
        var maxDepth = 0

        // Hash the builder type for context
        hasher.hashString("ResultBuilder:\(normalized.builderType.rawValue)")
        nodeCount += 1

        // Hash each normalized statement
        for statement in normalized.statements {
            let stats = hashNormalizedStatement(statement, hasher: &hasher, depth: 1)
            nodeCount += stats.nodeCount
            maxDepth = max(maxDepth, stats.depth)
        }

        return ASTFingerprint(
            hash: hasher.finalHash(),
            depth: maxDepth,
            nodeCount: nodeCount,
            rootKind: "NormalizedResultBuilder",
        )
    }

    /// Hash a normalized statement.
    private func hashNormalizedStatement(
        _ statement: NormalizedStatement,
        hasher: inout FingerprintHasher,
        depth: Int,
    ) -> FingerprintHasher.Stats {
        var stats = FingerprintHasher.Stats(depth: depth, nodeCount: 1)

        // Hash the statement kind and normalized content
        hasher.hashString("Statement:\(statement.kind.rawValue):\(statement.normalizedContent)")

        // Hash children recursively
        for child in statement.children {
            let childStats = hashNormalizedStatement(child, hasher: &hasher, depth: depth + 1)
            stats.nodeCount += childStats.nodeCount
            stats.depth = max(stats.depth, childStats.depth)
        }

        return stats
    }

    /// Compute a structural fingerprint for a syntax node.
    private func computeFingerprint(for node: Syntax) -> ASTFingerprint {
        var hasher = FingerprintHasher()
        let stats = hasher.hash(node)

        return ASTFingerprint(
            hash: hasher.finalHash(),
            depth: stats.depth,
            nodeCount: stats.nodeCount,
            rootKind: "\(node.kind)",
        )
    }

    /// Count tokens in a syntax node.
    private func countTokens(in node: some SyntaxProtocol) -> Int {
        var count = 0
        for _ in node.tokens(viewMode: .sourceAccurate) {
            count += 1
        }
        return count
    }
}

// MARK: - FingerprintHasher

/// Computes a structural hash of an AST.
struct FingerprintHasher {
    // MARK: Internal

    struct Stats {
        var depth: Int = 0
        var nodeCount: Int = 0
    }

    /// Hash a syntax node and return stats.
    mutating func hash(_ node: Syntax) -> Stats {
        var stats = Stats()
        hashNode(node, depth: 0, stats: &stats)
        return stats
    }

    /// Get the final hash value.
    func finalHash() -> UInt64 {
        hash
    }

    /// Hash a string and incorporate it into the hash.
    mutating func hashString(_ str: String) {
        let strHash = computeStringHash(str)
        hash = (hash &* 31 &+ strHash) % prime
    }

    // MARK: Private

    private var hash: UInt64 = 0
    private let prime: UInt64 = 1_000_000_007

    private mutating func hashNode(_ node: Syntax, depth: Int, stats: inout Stats) {
        stats.nodeCount += 1
        stats.depth = max(stats.depth, depth)

        // Hash the node kind (structure, not content)
        hashString("\(node.kind)")

        // Recursively hash children
        for child in node.children(viewMode: .sourceAccurate) {
            hashNode(child, depth: depth + 1, stats: &stats)
        }

        // Add closing marker for this level
        hash = (hash &* 31 &+ 0xDEAD_BEEF) % prime
    }

    private func computeStringHash(_ str: String) -> UInt64 {
        var h: UInt64 = 0
        for char in str.utf8 {
            h = (h &* 31 &+ UInt64(char)) % prime
        }
        return h
    }
}
