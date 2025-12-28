//
//  ASTFingerprintVisitor.swift
//  SwiftStaticAnalysis
//
//  Creates structural fingerprints of AST subtrees for semantic clone detection.
//

import Foundation
import SwiftSyntax
import SwiftStaticAnalysisCore

// MARK: - AST Fingerprint

/// A structural fingerprint of an AST subtree.
public struct ASTFingerprint: Sendable, Hashable {
    /// The hash of the structure.
    public let hash: UInt64

    /// The depth of the subtree.
    public let depth: Int

    /// Number of nodes in the subtree.
    public let nodeCount: Int

    /// The syntax kind at the root.
    public let rootKind: String

    public init(hash: UInt64, depth: Int, nodeCount: Int, rootKind: String) {
        self.hash = hash
        self.depth = depth
        self.nodeCount = nodeCount
        self.rootKind = rootKind
    }
}

// MARK: - Fingerprinted Node

/// An AST node with its fingerprint and location.
public struct FingerprintedNode: Sendable {
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

    public init(
        file: String,
        fingerprint: ASTFingerprint,
        startLine: Int,
        endLine: Int,
        startColumn: Int,
        tokenCount: Int
    ) {
        self.file = file
        self.fingerprint = fingerprint
        self.startLine = startLine
        self.endLine = endLine
        self.startColumn = startColumn
        self.tokenCount = tokenCount
    }
}

// MARK: - AST Fingerprint Visitor

/// Computes structural fingerprints for function and closure bodies.
public final class ASTFingerprintVisitor: SyntaxVisitor {
    /// Collected fingerprinted nodes.
    public private(set) var fingerprintedNodes: [FingerprintedNode] = []

    /// Source location converter.
    private let converter: SourceLocationConverter

    /// File path.
    private let file: String

    /// Minimum nodes to consider.
    private let minimumNodes: Int

    public init(file: String, tree: SourceFileSyntax, minimumNodes: Int = 10) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        self.minimumNodes = minimumNodes
        super.init(viewMode: .sourceAccurate)
    }

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

    // MARK: - Fingerprinting

    private func fingerprintCodeBlock(_ block: CodeBlockSyntax) {
        let result = computeFingerprint(for: Syntax(block))

        guard result.nodeCount >= minimumNodes else { return }

        let startLoc = converter.location(for: block.positionAfterSkippingLeadingTrivia)
        let endLoc = converter.location(for: block.endPositionBeforeTrailingTrivia)

        fingerprintedNodes.append(FingerprintedNode(
            file: file,
            fingerprint: result,
            startLine: startLoc.line,
            endLine: endLoc.line,
            startColumn: startLoc.column,
            tokenCount: countTokens(in: block)
        ))
    }

    private func fingerprintClosure(_ closure: ClosureExprSyntax) {
        let result = computeFingerprint(for: Syntax(closure))

        guard result.nodeCount >= minimumNodes else { return }

        let startLoc = converter.location(for: closure.positionAfterSkippingLeadingTrivia)
        let endLoc = converter.location(for: closure.endPositionBeforeTrailingTrivia)

        fingerprintedNodes.append(FingerprintedNode(
            file: file,
            fingerprint: result,
            startLine: startLoc.line,
            endLine: endLoc.line,
            startColumn: startLoc.column,
            tokenCount: countTokens(in: closure)
        ))
    }

    /// Compute a structural fingerprint for a syntax node.
    private func computeFingerprint(for node: Syntax) -> ASTFingerprint {
        var hasher = FingerprintHasher()
        let stats = hasher.hash(node)

        return ASTFingerprint(
            hash: hasher.finalHash(),
            depth: stats.depth,
            nodeCount: stats.nodeCount,
            rootKind: "\(node.kind)"
        )
    }

    /// Count tokens in a syntax node.
    private func countTokens<T: SyntaxProtocol>(in node: T) -> Int {
        var count = 0
        for _ in node.tokens(viewMode: .sourceAccurate) {
            count += 1
        }
        return count
    }
}

// MARK: - Fingerprint Hasher

/// Computes a structural hash of an AST.
private struct FingerprintHasher {
    private var hash: UInt64 = 0
    private let prime: UInt64 = 1_000_000_007

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

    private mutating func hashNode(_ node: Syntax, depth: Int, stats: inout Stats) {
        stats.nodeCount += 1
        stats.depth = max(stats.depth, depth)

        // Hash the node kind (structure, not content)
        let kindHash = hashString("\(node.kind)")
        hash = (hash &* 31 &+ kindHash) % prime

        // Recursively hash children
        for child in node.children(viewMode: .sourceAccurate) {
            hashNode(child, depth: depth + 1, stats: &stats)
        }

        // Add closing marker for this level
        hash = (hash &* 31 &+ 0xDEADBEEF) % prime
    }

    private func hashString(_ str: String) -> UInt64 {
        var h: UInt64 = 0
        for char in str.utf8 {
            h = (h &* 31 &+ UInt64(char)) % prime
        }
        return h
    }
}
