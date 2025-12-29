//
//  IndexBasedDependencyGraph.swift
//  SwiftStaticAnalysis
//
//  Dependency graph construction from IndexStoreDB data.
//
//  This module builds a comprehensive dependency graph by reading
//  the compiler's pre-built index, enabling accurate cross-module
//  reference tracking and protocol witness resolution.
//

import Foundation
import IndexStoreDB
import SwiftStaticAnalysisCore

// MARK: - IndexSymbolNode

/// A node in the dependency graph representing a symbol from the index.
public struct IndexSymbolNode: Hashable, Sendable {
    // MARK: Lifecycle

    public init(
        usr: String,
        name: String,
        kind: IndexedSymbolKind,
        definitionFile: String? = nil,
        definitionLine: Int? = nil,
        isRoot: Bool = false,
        rootReason: RootReason? = nil,
        isExternal: Bool = false,
    ) {
        self.usr = usr
        self.name = name
        self.kind = kind
        self.definitionFile = definitionFile
        self.definitionLine = definitionLine
        self.isRoot = isRoot
        self.rootReason = rootReason
        self.isExternal = isExternal
    }

    // MARK: Public

    /// The symbol's USR (Unified Symbol Reference).
    public let usr: String

    /// The symbol name.
    public let name: String

    /// The kind of symbol.
    public let kind: IndexedSymbolKind

    /// File where the symbol is defined.
    public let definitionFile: String?

    /// Line number of definition.
    public let definitionLine: Int?

    /// Whether this is a root node (entry point).
    public var isRoot: Bool

    /// Reason this is a root (if applicable).
    public var rootReason: RootReason?

    /// Whether this is an external (cross-module) symbol.
    public let isExternal: Bool

    public static func == (lhs: IndexSymbolNode, rhs: IndexSymbolNode) -> Bool {
        lhs.usr == rhs.usr
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(usr)
    }
}

// MARK: - IndexDependencyEdge

/// An edge representing a dependency between symbols.
public struct IndexDependencyEdge: Hashable, Sendable {
    // MARK: Lifecycle

    public init(fromUSR: String, toUSR: String, kind: IndexDependencyKind) {
        self.fromUSR = fromUSR
        self.toUSR = toUSR
        self.kind = kind
    }

    // MARK: Public

    /// Source symbol USR.
    public let fromUSR: String

    /// Target symbol USR.
    public let toUSR: String

    /// The kind of dependency.
    public let kind: IndexDependencyKind
}

// MARK: - IndexDependencyKind

/// Kinds of dependencies detected from the index.
/// Exhaustive coverage for dependency graph edges. // swa:ignore-unused-cases
public enum IndexDependencyKind: String, Sendable, Codable {
    /// Direct function/method call.
    case call

    /// Type reference.
    case typeReference

    /// Inheritance (class) or conformance (protocol).
    case inheritance

    /// Protocol witness (implementation of protocol requirement).
    case protocolWitness

    /// Property read.
    case read

    /// Property write.
    case write

    /// Extension target.
    case extensionOf

    /// Contained by (e.g., method in class).
    case containedBy

    /// Override relationship.
    case override
}

// MARK: - IndexBasedDependencyGraph

/// Dependency graph built from IndexStoreDB data.
///
/// This graph provides accurate cross-module dependency tracking
/// by leveraging the compiler's pre-built index store.
public final class IndexBasedDependencyGraph: @unchecked Sendable {
    // MARK: Lifecycle

    public init(analysisFiles: [String], configuration: IndexGraphConfiguration = .default) {
        self.analysisFiles = Set(analysisFiles.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        self.configuration = configuration
    }

    // MARK: Public

    /// Configuration for root detection.
    public let configuration: IndexGraphConfiguration

    // MARK: - Graph Information

    /// Get all root nodes.
    public var rootNodes: [IndexSymbolNode] {
        roots.compactMap { nodes[$0] }
    }

    /// Total number of nodes.
    public var nodeCount: Int { nodes.count }

    /// Total number of edges.
    public var edgeCount: Int {
        edges.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Graph Building

    /// Build the dependency graph from an IndexStoreDB instance.
    ///
    /// - Parameter db: The IndexStoreDB database.
    public func build(from db: IndexStoreDB) {
        lock.lock()
        defer { lock.unlock() }

        // Clear any existing data
        nodes.removeAll()
        edges.removeAll()
        reverseEdges.removeAll()
        roots.removeAll()
        reachableCache = nil

        // First pass: collect all definitions in analysis files
        collectDefinitions(from: db)

        // Second pass: build edges from references
        buildEdges(from: db)

        // Third pass: resolve protocol witnesses
        resolveProtocolWitnesses(from: db)

        // Fourth pass: detect roots
        detectRoots()
    }

    // MARK: - Reachability Analysis

    /// Compute all reachable nodes from the root set using BFS.
    public func computeReachable() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        if let cached = reachableCache {
            return cached
        }

        var reachable = Set<String>()
        var queue = Array(roots)
        var visited = Set<String>()

        while !queue.isEmpty {
            let current = queue.removeFirst()

            if visited.contains(current) {
                continue
            }
            visited.insert(current)
            reachable.insert(current)

            // Add all targets of outgoing edges
            if let outgoing = edges[current] {
                for edge in outgoing {
                    if !visited.contains(edge.toUSR) {
                        queue.append(edge.toUSR)
                    }
                }
            }
        }

        reachableCache = reachable
        return reachable
    }

    /// Get all unreachable nodes (excluding external symbols).
    public func computeUnreachable() -> [IndexSymbolNode] {
        let reachable = computeReachable()
        return nodes.values.filter { node in
            !reachable.contains(node.usr) && !node.isExternal
        }
    }

    /// Check if a symbol is reachable.
    public func isReachable(usr: String) -> Bool {
        computeReachable().contains(usr)
    }

    /// Get a node by USR.
    public func node(for usr: String) -> IndexSymbolNode? {
        nodes[usr]
    }

    /// Get outgoing edges for a node.
    public func outgoingEdges(for usr: String) -> Set<IndexDependencyEdge> {
        edges[usr] ?? []
    }

    /// Get incoming edges for a node.
    public func incomingEdges(for usr: String) -> Set<IndexDependencyEdge> {
        reverseEdges[usr] ?? []
    }

    // MARK: Private

    /// All nodes in the graph.
    private var nodes: [String: IndexSymbolNode] = [:]

    /// Adjacency list (outgoing edges from each node).
    private var edges: [String: Set<IndexDependencyEdge>] = [:]

    /// Reverse adjacency list (incoming edges to each node).
    private var reverseEdges: [String: Set<IndexDependencyEdge>] = [:]

    /// Root node USRs.
    private var roots: Set<String> = []

    /// Cache of reachable nodes.
    private var reachableCache: Set<String>?

    /// Files included in the analysis scope.
    private let analysisFiles: Set<String>

    /// Lock for thread safety.
    private let lock = NSLock()

    /// Collect all symbol definitions from files in scope.
    private func collectDefinitions(from db: IndexStoreDB) {
        for filePath in analysisFiles {
            let occurrences = db.symbolOccurrences(inFilePath: filePath)
            for occurrence in occurrences {
                let roles = occurrence.roles

                // Only process definitions and declarations
                guard roles.contains(.definition) || roles.contains(.declaration) else {
                    continue
                }

                let symbol = occurrence.symbol
                let usr = symbol.usr

                // Skip if already seen
                guard nodes[usr] == nil else { continue }

                let node = IndexSymbolNode(
                    usr: usr,
                    name: symbol.name,
                    kind: IndexedSymbolKind(from: symbol.kind),
                    definitionFile: occurrence.location.path,
                    definitionLine: occurrence.location.line,
                    isExternal: false,
                )

                nodes[usr] = node
            }
        }
    }

    /// Build edges from all references.
    private func buildEdges(from db: IndexStoreDB) {
        for filePath in analysisFiles {
            let occurrences = db.symbolOccurrences(inFilePath: filePath)
            for occurrence in occurrences {
                processOccurrence(occurrence, from: db)
            }
        }
    }

    /// Process a single occurrence to extract edges.
    private func processOccurrence(_ occurrence: SymbolOccurrence, from db: IndexStoreDB) {
        let roles = occurrence.roles
        let targetUSR = occurrence.symbol.usr

        // Skip definitions without relations
        guard roles.contains(.reference) ||
            roles.contains(.call) ||
            roles.contains(.read) ||
            roles.contains(.write)
        else {
            return
        }

        // Find the containing symbol (the "from" in the edge)
        // This requires looking at the relations
        for relation in occurrence.relations {
            let relatedUSR = relation.symbol.usr
            let relatedRoles = relation.roles

            // containedBy means this occurrence is inside that symbol
            if relatedRoles.contains(.containedBy) {
                // The containing symbol references the target
                let kind: IndexDependencyKind = if roles.contains(.call) {
                    .call
                } else if roles.contains(.read) {
                    .read
                } else if roles.contains(.write) {
                    .write
                } else {
                    .typeReference
                }

                addEdge(from: relatedUSR, to: targetUSR, kind: kind)
            }

            // baseOf means this symbol is a base of (extended by) the related symbol
            if relatedRoles.contains(.baseOf) {
                addEdge(from: targetUSR, to: relatedUSR, kind: .inheritance)
            }

            // overrideOf means this symbol overrides the related symbol
            if relatedRoles.contains(.overrideOf) {
                addEdge(from: targetUSR, to: relatedUSR, kind: .override)
            }
        }

        // Ensure the target node exists (might be external)
        ensureNodeExists(usr: targetUSR, symbol: occurrence.symbol, isExternal: true)
    }

    /// Resolve protocol witness relationships.
    ///
    /// When a type conforms to a protocol, implementations of protocol
    /// requirements are implicitly referenced when the protocol is used.
    private func resolveProtocolWitnesses(from db: IndexStoreDB) {
        // Find all protocols in our nodes
        let protocols = nodes.values.filter { $0.kind == .protocol }

        for proto in protocols {
            // Find all occurrences related to this protocol (conformances)
            db.forEachRelatedSymbolOccurrence(byUSR: proto.usr, roles: .baseOf) { occurrence in
                // This is a type that conforms to the protocol
                let conformingTypeUSR = occurrence.symbol.usr

                // The conforming type's implementations are witnesses
                // Add edges from protocol requirements to implementations
                self.linkProtocolWitnesses(
                    protocolUSR: proto.usr,
                    conformingTypeUSR: conformingTypeUSR,
                    db: db,
                )

                return true
            }
        }
    }

    /// Link protocol requirements to their implementations in a conforming type.
    private func linkProtocolWitnesses(
        protocolUSR: String,
        conformingTypeUSR: String,
        db: IndexStoreDB,
    ) {
        // Get all members of the protocol
        db.forEachRelatedSymbolOccurrence(byUSR: protocolUSR, roles: .containedBy) { protoMember in
            let memberName = protoMember.symbol.name

            // Find matching implementation in conforming type
            db.forEachRelatedSymbolOccurrence(byUSR: conformingTypeUSR, roles: .containedBy) { typeMember in
                if typeMember.symbol.name == memberName {
                    // This is likely a witness
                    addEdge(
                        from: protoMember.symbol.usr,
                        to: typeMember.symbol.usr,
                        kind: .protocolWitness,
                    )
                }
                return true
            }

            return true
        }
    }

    /// Ensure a node exists in the graph.
    private func ensureNodeExists(usr: String, symbol: Symbol, isExternal: Bool) {
        guard nodes[usr] == nil else { return }

        let node = IndexSymbolNode(
            usr: usr,
            name: symbol.name,
            kind: IndexedSymbolKind(from: symbol.kind),
            isExternal: isExternal,
        )
        nodes[usr] = node
    }

    /// Add an edge to the graph.
    private func addEdge(from: String, to: String, kind: IndexDependencyKind) {
        let edge = IndexDependencyEdge(fromUSR: from, toUSR: to, kind: kind)
        edges[from, default: []].insert(edge)
        reverseEdges[to, default: []].insert(edge)
        reachableCache = nil
    }

    // MARK: - Root Detection

    /// Detect root nodes based on configuration.
    private func detectRoots() {
        for (usr, node) in nodes {
            if let reason = determineRootReason(for: node) {
                var mutableNode = node
                mutableNode.isRoot = true
                mutableNode.rootReason = reason
                nodes[usr] = mutableNode
                roots.insert(usr)
            }
        }
    }

    /// Determine if a node should be a root and why.
    private func determineRootReason(for node: IndexSymbolNode) -> RootReason? {
        // External symbols are not roots (they're sinks)
        if node.isExternal {
            return nil
        }

        // Check for main entry points
        if node.name == "main", node.kind == .function || node.kind == .method {
            return .mainFunction
        }

        // Check for test methods
        if configuration.treatTestsAsRoot,
           node.name.hasPrefix("test"),
           node.kind == .function || node.kind == .method {
            return .testMethod
        }

        // Check file path for test indicator
        if configuration.treatTestsAsRoot,
           let file = node.definitionFile,
           file.contains("Tests") || file.contains("Test") {
            if node.kind == .function || node.kind == .method {
                return .testMethod
            }
        }

        // Protocol requirements can be roots (called via protocol)
        if configuration.treatProtocolRequirementsAsRoot, node.kind == .protocol {
            return .protocolWitness
        }

        return nil
    }
}

// MARK: - IndexGraphConfiguration

/// Configuration for index-based dependency graph.
public struct IndexGraphConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        treatTestsAsRoot: Bool = true,
        treatProtocolRequirementsAsRoot: Bool = true,
        includeCrossModuleEdges: Bool = true,
        trackProtocolWitnesses: Bool = true,
    ) {
        self.treatTestsAsRoot = treatTestsAsRoot
        self.treatProtocolRequirementsAsRoot = treatProtocolRequirementsAsRoot
        self.includeCrossModuleEdges = includeCrossModuleEdges
        self.trackProtocolWitnesses = trackProtocolWitnesses
    }

    // MARK: Public

    public static let `default` = IndexGraphConfiguration()

    /// Treat test methods as roots.
    public var treatTestsAsRoot: Bool

    /// Treat protocol requirements as roots.
    public var treatProtocolRequirementsAsRoot: Bool

    /// Include cross-module edges.
    public var includeCrossModuleEdges: Bool

    /// Track protocol witnesses.
    public var trackProtocolWitnesses: Bool
}

// MARK: - IndexGraphReport

/// Report from index-based graph analysis.
public struct IndexGraphReport: Sendable {
    // MARK: Lifecycle

    public init(
        totalSymbols: Int,
        rootCount: Int,
        reachableCount: Int,
        unreachableCount: Int,
        externalCount: Int,
        edgeCount: Int,
        unreachableByKind: [IndexedSymbolKind: Int],
        rootsByReason: [RootReason: Int],
    ) {
        self.totalSymbols = totalSymbols
        self.rootCount = rootCount
        self.reachableCount = reachableCount
        self.unreachableCount = unreachableCount
        self.externalCount = externalCount
        self.edgeCount = edgeCount
        self.unreachableByKind = unreachableByKind
        self.rootsByReason = rootsByReason
    }

    // MARK: Public

    /// Total symbols analyzed.
    public let totalSymbols: Int

    /// Number of root symbols.
    public let rootCount: Int

    /// Number of reachable symbols.
    public let reachableCount: Int

    /// Number of unreachable symbols.
    public let unreachableCount: Int

    /// Number of external (cross-module) symbols.
    public let externalCount: Int

    /// Number of edges in the graph.
    public let edgeCount: Int

    /// Unreachable symbols grouped by kind.
    public let unreachableByKind: [IndexedSymbolKind: Int]

    /// Roots grouped by reason.
    public let rootsByReason: [RootReason: Int]

    /// Percentage of code that is reachable.
    public var reachabilityPercentage: Double {
        guard totalSymbols > 0 else { return 100.0 }
        let nonExternal = totalSymbols - externalCount
        guard nonExternal > 0 else { return 100.0 }
        return Double(reachableCount) / Double(nonExternal) * 100.0
    }
}

public extension IndexBasedDependencyGraph {
    /// Generate a report of the analysis.
    func generateReport() -> IndexGraphReport {
        let reachable = computeReachable()
        let unreachableNodes = computeUnreachable()
        let externalNodes = nodes.values.filter(\.isExternal)

        var unreachableByKind: [IndexedSymbolKind: Int] = [:]
        for node in unreachableNodes {
            unreachableByKind[node.kind, default: 0] += 1
        }

        var rootsByReason: [RootReason: Int] = [:]
        for usr in roots {
            if let node = nodes[usr], let reason = node.rootReason {
                rootsByReason[reason, default: 0] += 1
            }
        }

        return IndexGraphReport(
            totalSymbols: nodes.count,
            rootCount: roots.count,
            reachableCount: reachable.count,
            unreachableCount: unreachableNodes.count,
            externalCount: externalNodes.count,
            edgeCount: edgeCount,
            unreachableByKind: unreachableByKind,
            rootsByReason: rootsByReason,
        )
    }
}
