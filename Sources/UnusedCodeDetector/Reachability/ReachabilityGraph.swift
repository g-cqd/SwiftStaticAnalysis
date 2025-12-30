//
//  ReachabilityGraph.swift
//  SwiftStaticAnalysis
//
//  Graph-based reachability analysis for unused code detection.
//  Uses BFS traversal from root sets (entry points) to find reachable code.
//

import SwiftStaticAnalysisCore

// MARK: - DeclarationNode

/// A node in the reachability graph representing a declaration.
public struct DeclarationNode: Hashable, Sendable {
    // MARK: Lifecycle

    public init(declaration: Declaration, isRoot: Bool = false, rootReason: RootReason? = nil) {
        id = "\(declaration.location.file):\(declaration.location.line):\(declaration.name)"
        self.declaration = declaration
        self.isRoot = isRoot
        self.rootReason = rootReason
    }

    // MARK: Public

    /// Unique identifier for this node (typically: file:line:name).
    public let id: String

    /// The declaration this node represents.
    public let declaration: Declaration

    /// Whether this is a root node (entry point).
    public let isRoot: Bool

    /// Reason this is a root (if applicable).
    public let rootReason: RootReason?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - RootReason

/// Reasons why a declaration is considered a root (entry point).
public enum RootReason: String, Sendable, Codable {
    /// Marked with @main attribute.
    case mainAttribute

    /// Marked with @UIApplicationMain.
    case uiApplicationMain

    /// Marked with @NSApplicationMain.
    case nsApplicationMain

    /// Public or open API (may be used externally).
    case publicAPI

    /// Exposed to Objective-C via @objc.
    case objcExposed

    /// Connected via Interface Builder (@IBAction, @IBOutlet).
    case interfaceBuilder

    /// Satisfies a protocol requirement.
    case protocolWitness

    /// Test method (methods starting with "test").
    case testMethod

    /// Required by Codable.
    case codableRequirement

    /// Main function (non-attribute based).
    case mainFunction

    /// Static main() in a type.
    case staticMain

    /// @dynamicMemberLookup or @dynamicCallable.
    case dynamicFeature

    // MARK: - SwiftUI Roots

    /// SwiftUI View type (body property is implicitly used).
    case swiftUIView

    /// SwiftUI App entry point.
    case swiftUIApp

    /// SwiftUI PreviewProvider.
    case swiftUIPreview

    /// SwiftUI property wrapper (@State, @Binding, etc.).
    case swiftUIPropertyWrapper

    /// View body property.
    case viewBody
}

// MARK: - DependencyEdge

/// An edge in the reachability graph representing a dependency.
public struct DependencyEdge: Hashable, Sendable {
    // MARK: Lifecycle

    public init(from: String, to: String, kind: DependencyKind) {
        self.from = from
        self.to = to
        self.kind = kind
    }

    // MARK: Public

    /// Source node ID.
    public let from: String

    /// Target node ID.
    public let to: String

    /// Kind of dependency.
    public let kind: DependencyKind
}

// MARK: - DependencyKind

/// Kinds of dependencies between declarations.
/// Exhaustive coverage for reachability analysis. // swa:ignore-unused-cases
public enum DependencyKind: String, Sendable, Codable {
    /// Direct function/method call.
    case call

    /// Type reference (variable type, parameter type, return type).
    case typeReference

    /// Inheritance or protocol conformance.
    case inheritance

    /// Property access.
    case propertyAccess

    /// Closure capture.
    case closureCapture

    /// Generic constraint.
    case genericConstraint

    /// Key path reference.
    case keyPath

    /// Extension target.
    case extensionTarget
}

// MARK: - ReachabilityGraph

/// Graph for analyzing code reachability from entry points.
///
/// ## Thread Safety Design
///
/// This type uses Swift's `actor` model for thread safety. This is the preferred
/// approach in modern Swift concurrency because:
///
/// 1. **No External Dependencies**: All types used by this graph (`Declaration`,
///    `DeclarationNode`, `DependencyEdge`) are `Sendable`, allowing safe actor isolation.
///
/// 2. **Compile-Time Safety**: The actor model provides compile-time guarantees
///    against data races, unlike `NSLock` which relies on correct manual usage.
///
/// 3. **Structured Concurrency**: Integrates naturally with Swift's `async`/`await`
///    pattern used throughout the codebase.
///
/// - SeeAlso: `IndexBasedDependencyGraph` which uses `NSLock` instead because
///   it depends on the non-`Sendable` `IndexStoreDB` type.
public actor ReachabilityGraph {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    // MARK: - Graph Information

    /// Get all root nodes.
    public var rootNodes: [DeclarationNode] {
        roots.compactMap { nodes[$0] }
    }

    /// Get the total number of nodes.
    public var nodeCount: Int {
        nodes.count
    }

    /// Get the total number of edges.
    public var edgeCount: Int {
        edges.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Building the Graph

    /// Add a declaration node to the graph.
    @discardableResult
    public func addNode(
        _ declaration: Declaration,
        isRoot: Bool = false,
        rootReason: RootReason? = nil
    ) -> DeclarationNode {
        let node = DeclarationNode(declaration: declaration, isRoot: isRoot, rootReason: rootReason)
        nodes[node.id] = node

        if isRoot {
            roots.insert(node.id)
        }

        // Invalidate cache
        reachableCache = nil

        return node
    }

    /// Add an edge between two nodes.
    public func addEdge(from: String, to: String, kind: DependencyKind) {
        let edge = DependencyEdge(from: from, to: to, kind: kind)
        edges[from, default: []].insert(edge)
        reverseEdges[to, default: []].insert(edge)

        // Invalidate cache
        reachableCache = nil
    }

    /// Add an edge between two declarations.
    public func addEdge(from: Declaration, to: Declaration, kind: DependencyKind) {
        let fromNode = DeclarationNode(declaration: from)
        let toNode = DeclarationNode(declaration: to)
        addEdge(from: fromNode.id, to: toNode.id, kind: kind)
    }

    // MARK: - Root Detection

    /// Detect and mark root nodes based on declarations and references.
    public func detectRoots(
        declarations: [Declaration],
        references: ReferenceIndex,
        configuration: RootDetectionConfiguration = .default
    ) {
        for declaration in declarations {
            if let reason = determineRootReason(for: declaration, configuration: configuration) {
                addNode(declaration, isRoot: true, rootReason: reason)
            } else {
                addNode(declaration, isRoot: false)
            }
        }
    }

    // MARK: - Reachability Analysis

    // swa:ignore-duplicates - Standard BFS reachability algorithm used in multiple graph implementations
    /// Compute all reachable nodes from the root set using BFS.
    public func computeReachable() -> Set<String> {
        // Return cached result if available
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
                for edge in outgoing where !visited.contains(edge.to) {
                    queue.append(edge.to)
                }
            }
        }

        reachableCache = reachable
        return reachable
    }

    /// Get all unreachable nodes.
    public func computeUnreachable() -> [DeclarationNode] {
        let reachable = computeReachable()
        return nodes.values.filter { !reachable.contains($0.id) }
    }

    /// Check if a specific declaration is reachable.
    public func isReachable(_ declaration: Declaration) -> Bool {
        let node = DeclarationNode(declaration: declaration)
        return computeReachable().contains(node.id)
    }

    /// Check if a node ID is reachable.
    public func isReachable(nodeId: String) -> Bool {
        computeReachable().contains(nodeId)
    }

    /// Get a node by ID.
    public func node(for id: String) -> DeclarationNode? {
        nodes[id]
    }

    /// Get outgoing edges for a node.
    public func outgoingEdges(for nodeId: String) -> Set<DependencyEdge> {
        edges[nodeId] ?? []
    }

    /// Get incoming edges for a node.
    public func incomingEdges(for nodeId: String) -> Set<DependencyEdge> {
        reverseEdges[nodeId] ?? []
    }

    // MARK: - Path Finding

    /// Find the shortest path from any root to a given node.
    /// Returns nil if the node is unreachable.
    public func findPathFromRoot(to targetId: String) -> [String]? {
        var queue: [(String, [String])] = roots.map { ($0, [$0]) }
        var visited = Set<String>()

        while !queue.isEmpty {
            let (current, path) = queue.removeFirst()

            if current == targetId {
                return path
            }

            if visited.contains(current) {
                continue
            }
            visited.insert(current)

            if let outgoing = edges[current] {
                for edge in outgoing where !visited.contains(edge.to) {
                    queue.append((edge.to, path + [edge.to]))
                }
            }
        }

        return nil
    }

    // MARK: Private

    /// All nodes in the graph.
    private var nodes: [String: DeclarationNode] = [:]

    /// Adjacency list (edges from each node).
    private var edges: [String: Set<DependencyEdge>] = [:]

    /// Reverse adjacency list (edges to each node).
    private var reverseEdges: [String: Set<DependencyEdge>] = [:]

    /// Root nodes (entry points).
    private var roots: Set<String> = []

    /// Cache of reachable nodes.
    private var reachableCache: Set<String>?

    /// Determine if a declaration should be a root and why.
    private func determineRootReason(  // swiftlint:disable:this cyclomatic_complexity function_body_length
        for declaration: Declaration,
        configuration: RootDetectionConfiguration,
    ) -> RootReason? {
        // Check for @main attribute
        if hasAttribute(declaration, named: "main") {
            return .mainAttribute
        }

        // Check for @UIApplicationMain
        if hasAttribute(declaration, named: "UIApplicationMain") {
            return .uiApplicationMain
        }

        // Check for @NSApplicationMain
        if hasAttribute(declaration, named: "NSApplicationMain") {
            return .nsApplicationMain
        }

        // Check for main function
        if declaration.name == "main" && declaration.kind == .function {
            return .mainFunction
        }

        // Check for static main() in a type
        if declaration.name == "main" && declaration.modifiers.contains(.static) {
            return .staticMain
        }

        // Check for public/open API
        if configuration.treatPublicAsRoot && declaration.accessLevel >= .public {
            return .publicAPI
        }

        // Check for @objc exposure
        if configuration.treatObjcAsRoot && hasAttribute(declaration, named: "objc") {
            return .objcExposed
        }

        // Check for Interface Builder connections
        if hasAttribute(declaration, named: "IBAction") || hasAttribute(declaration, named: "IBOutlet")
            || hasAttribute(declaration, named: "IBInspectable") || hasAttribute(declaration, named: "IBDesignable")
        {
            return .interfaceBuilder
        }

        // Check for test methods
        if configuration.treatTestsAsRoot && declaration.name.hasPrefix("test")
            && (declaration.kind == .function || declaration.kind == .method)
        {
            return .testMethod
        }

        // Check for Codable requirements (CodingKeys, encode, init(from:))
        if declaration.name == "CodingKeys" && declaration.kind == .enum {
            return .codableRequirement
        }

        if (declaration.name == "encode" || declaration.name == "init") && declaration.kind == .function {
            // Could be Codable - mark as potential root with low confidence
            // This should be refined with type information
        }

        // Check for dynamic features
        if hasAttribute(declaration, named: "dynamicMemberLookup")
            || hasAttribute(declaration, named: "dynamicCallable")
        {
            return .dynamicFeature
        }

        // MARK: - SwiftUI Root Detection

        // Check for SwiftUI App
        if configuration.treatSwiftUIViewsAsRoot, declaration.isSwiftUIApp {
            return .swiftUIApp
        }

        // Check for SwiftUI View
        if configuration.treatSwiftUIViewsAsRoot, declaration.isSwiftUIView {
            return .swiftUIView
        }

        // Check for PreviewProvider
        if configuration.treatPreviewProvidersAsRoot, declaration.isSwiftUIPreview {
            return .swiftUIPreview
        }

        // Check for SwiftUI property wrappers
        if configuration.treatSwiftUIPropertyWrappersAsRoot, declaration.hasImplicitUsageWrapper {
            return .swiftUIPropertyWrapper
        }

        // Check for View body property
        if configuration.treatSwiftUIViewsAsRoot,
            declaration.name == "body",
            declaration.kind == .variable
        {
            return .viewBody
        }

        return nil
    }

    /// Check if a declaration has a specific attribute.
    private func hasAttribute(_ declaration: Declaration, named name: String) -> Bool {
        // Check the attributes array extracted from the syntax tree
        if declaration.attributes.contains(name) {
            return true
        }

        // Fallback: check documentation for attribute markers
        if let doc = declaration.documentation {
            if doc.contains("@\(name)") {
                return true
            }
        }

        return false
    }
}

// MARK: - RootDetectionConfiguration

/// Configuration for root detection.
public struct RootDetectionConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        treatPublicAsRoot: Bool = true,
        treatObjcAsRoot: Bool = true,
        treatTestsAsRoot: Bool = true,
        treatProtocolRequirementsAsRoot: Bool = true,
        treatSwiftUIViewsAsRoot: Bool = true,
        treatSwiftUIPropertyWrappersAsRoot: Bool = true,
        treatPreviewProvidersAsRoot: Bool = true,
    ) {
        self.treatPublicAsRoot = treatPublicAsRoot
        self.treatObjcAsRoot = treatObjcAsRoot
        self.treatTestsAsRoot = treatTestsAsRoot
        self.treatProtocolRequirementsAsRoot = treatProtocolRequirementsAsRoot
        self.treatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot
        self.treatSwiftUIPropertyWrappersAsRoot = treatSwiftUIPropertyWrappersAsRoot
        self.treatPreviewProvidersAsRoot = treatPreviewProvidersAsRoot
    }

    // MARK: Public

    /// Default configuration.
    public static let `default` = Self()

    /// Strict configuration (only explicit entry points).
    public static let strict = Self(
        treatPublicAsRoot: false,
        treatObjcAsRoot: true,
        treatTestsAsRoot: true,
        treatProtocolRequirementsAsRoot: true,
        treatSwiftUIViewsAsRoot: true,
        treatSwiftUIPropertyWrappersAsRoot: true,
        treatPreviewProvidersAsRoot: false,
    )

    /// Treat public/open declarations as roots.
    public var treatPublicAsRoot: Bool

    /// Treat @objc declarations as roots.
    public var treatObjcAsRoot: Bool

    /// Treat test methods as roots.
    public var treatTestsAsRoot: Bool

    /// Treat protocol requirements as roots.
    public var treatProtocolRequirementsAsRoot: Bool

    // MARK: - SwiftUI Configuration

    /// Treat SwiftUI Views as roots.
    public var treatSwiftUIViewsAsRoot: Bool

    /// Treat SwiftUI property wrappers as roots.
    public var treatSwiftUIPropertyWrappersAsRoot: Bool

    /// Treat PreviewProviders as roots.
    public var treatPreviewProvidersAsRoot: Bool
}

// MARK: - ReachabilityReport

/// Report of reachability analysis.
public struct ReachabilityReport: Sendable {
    // MARK: Lifecycle

    public init(
        totalDeclarations: Int,
        rootCount: Int,
        reachableCount: Int,
        unreachableCount: Int,
        unreachableByKind: [DeclarationKind: Int],
        rootsByReason: [RootReason: Int],
    ) {
        self.totalDeclarations = totalDeclarations
        self.rootCount = rootCount
        self.reachableCount = reachableCount
        self.unreachableCount = unreachableCount
        self.unreachableByKind = unreachableByKind
        self.rootsByReason = rootsByReason
    }

    // MARK: Public

    /// Total declarations analyzed.
    public let totalDeclarations: Int

    /// Number of root declarations.
    public let rootCount: Int

    /// Number of reachable declarations.
    public let reachableCount: Int

    /// Number of unreachable declarations.
    public let unreachableCount: Int

    /// Unreachable declarations grouped by kind.
    public let unreachableByKind: [DeclarationKind: Int]

    /// Root declarations grouped by reason.
    public let rootsByReason: [RootReason: Int]

    /// Percentage of code that is reachable.
    public var reachabilityPercentage: Double {
        guard totalDeclarations > 0 else { return 100.0 }
        return Double(reachableCount) / Double(totalDeclarations) * 100.0
    }
}

extension ReachabilityGraph {
    /// Generate a report of the reachability analysis.
    public func generateReport() -> ReachabilityReport {
        let reachable = computeReachable()
        let unreachableNodes = computeUnreachable()

        var unreachableByKind: [DeclarationKind: Int] = [:]
        for node in unreachableNodes {
            unreachableByKind[node.declaration.kind, default: 0] += 1
        }

        var rootsByReason: [RootReason: Int] = [:]
        for rootId in roots {
            if let node = nodes[rootId], let reason = node.rootReason {
                rootsByReason[reason, default: 0] += 1
            }
        }

        return ReachabilityReport(
            totalDeclarations: nodes.count,
            rootCount: roots.count,
            reachableCount: reachable.count,
            unreachableCount: unreachableNodes.count,
            unreachableByKind: unreachableByKind,
            rootsByReason: rootsByReason,
        )
    }
}
