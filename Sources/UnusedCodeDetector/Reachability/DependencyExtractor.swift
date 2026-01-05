//  DependencyExtractor.swift
//  SwiftStaticAnalysis
//  MIT License

import AsyncAlgorithms
import Foundation
import SwiftStaticAnalysisCore

// MARK: - DependencyExtractor

/// Extracts dependencies from analysis results to build a reachability graph.
///
/// ## Parallelism Design
///
/// Edge computation is parallelized for performance on large codebases:
///
/// 1. **Edge Computation (Parallel)**: The `buildEdges()` method uses `ParallelProcessor`
///    to compute edges for each declaration concurrently. This is safe because:
///    - Edge computation is a pure function with no shared mutable state
///    - Each declaration's edges are independent of others
///    - Results are collected into immutable arrays
///
/// 2. **Batch Insertion (Sequential)**: After parallel computation, edges are batch-inserted
///    into the `ReachabilityGraph` actor in a single call, minimizing actor hop overhead.
///
/// 3. **BFS Reachability (Sequential)**: The reachability computation in `ReachabilityGraph`
///    uses standard BFS which is inherently sequential. This is mathematically correct:
///    - BFS requires visiting nodes in order by distance from roots
///    - Each iteration depends on the previous iteration's results
///    - Parallel BFS exists but adds significant complexity for minimal gain on typical graphs
///
/// ## Performance Characteristics
///
/// - Small codebases (<100 declarations): Minimal benefit, overhead may dominate
/// - Medium codebases (100-1000 declarations): ~2-4x speedup
/// - Large codebases (1000+ declarations): ~4-8x speedup (CPU-core dependent)
///
public struct DependencyExtractor: Sendable {
    // MARK: Lifecycle

    public init(configuration: DependencyExtractionConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: Public

    /// Configuration for extraction.
    public let configuration: DependencyExtractionConfiguration

    /// Build a reachability graph from analysis results.
    public func buildGraph(from result: AnalysisResult) async -> ReachabilityGraph {
        let graph = ReachabilityGraph()

        // Add all declarations as nodes and detect roots
        let rootConfig = RootDetectionConfiguration(
            treatPublicAsRoot: configuration.treatPublicAsRoot,
            treatObjcAsRoot: configuration.treatObjcAsRoot,
            treatTestsAsRoot: configuration.treatTestsAsRoot,
            treatProtocolRequirementsAsRoot: configuration.treatProtocolRequirementsAsRoot,
            treatSwiftUIViewsAsRoot: configuration.treatSwiftUIViewsAsRoot,
            treatSwiftUIPropertyWrappersAsRoot: configuration.treatSwiftUIPropertyWrappersAsRoot,
            treatPreviewProvidersAsRoot: configuration.treatPreviewProvidersAsRoot
        )

        await graph.detectRoots(
            declarations: result.declarations.declarations,
            references: result.references,
            configuration: rootConfig
        )

        // Build edges based on references
        await buildEdges(graph: graph, result: result)

        return graph
    }

    // MARK: Private

    /// Build edges between declarations based on references.
    /// Uses parallel processing to compute edges concurrently, then batch-inserts them.
    private func buildEdges(graph: ReachabilityGraph, result: AnalysisResult) async {
        let declarations = result.declarations
        let references = result.references

        // Create a lookup from name to declarations (sequential - fast O(n))
        var declByNameMutable: [String: [Declaration]] = [:]
        for decl in declarations.declarations {
            declByNameMutable[decl.name, default: []].append(decl)
        }
        let declByName = declByNameMutable  // Immutable copy for Sendable closure capture

        // Compute edges in parallel
        let allDeclarations = declarations.declarations
        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount

        let computedEdges = await ParallelProcessor.compactMap(
            allDeclarations,
            maxConcurrency: maxConcurrency
        ) { declaration -> [DependencyEdge]? in
            let edges = self.computeEdgesForDeclaration(
                declaration,
                references: references,
                declByName: declByName
            )
            return edges.isEmpty ? nil : edges
        }

        // Batch insert all edges (single actor call)
        let flattenedEdges = computedEdges.flatMap { $0 }
        await graph.addEdges(flattenedEdges)

        // Handle protocol witnesses (also parallelized)
        if configuration.trackProtocolWitnesses {
            await addProtocolWitnessEdgesParallel(
                graph: graph,
                result: result,
                declByName: declByName
            )
        }
    }

    /// Stream edges as they're computed (for ParallelMode.maximum).
    ///
    /// This method yields edges incrementally, reducing peak memory for large codebases.
    /// Each declaration's edges are computed and yielded immediately.
    ///
    /// - Parameters:
    ///   - result: The analysis result containing declarations and references.
    ///   - bufferSize: Size of the streaming buffer for backpressure.
    /// - Returns: AsyncStream of dependency edges.
    public func streamEdges(
        from result: AnalysisResult,
        bufferSize: Int = 1000
    ) -> AsyncStream<DependencyEdge> {
        let declarations = result.declarations
        let references = result.references

        // Create a lookup from name to declarations
        var declByNameMutable: [String: [Declaration]] = [:]
        for decl in declarations.declarations {
            declByNameMutable[decl.name, default: []].append(decl)
        }
        let declByName = declByNameMutable

        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            Task {
                for declaration in declarations.declarations {
                    let edges = self.computeEdgesForDeclaration(
                        declaration,
                        references: references,
                        declByName: declByName
                    )
                    for edge in edges {
                        continuation.yield(edge)
                    }
                }

                // Also stream protocol witness edges
                if self.configuration.trackProtocolWitnesses {
                    for await edge in self.streamProtocolWitnessEdges(
                        result: result,
                        declByName: declByName
                    ) {
                        continuation.yield(edge)
                    }
                }

                continuation.finish()
            }
        }
    }

    /// Stream protocol witness edges.
    private func streamProtocolWitnessEdges(
        result: AnalysisResult,
        declByName: [String: [Declaration]]
    ) -> AsyncStream<DependencyEdge> {
        let protocols = result.declarations.find(kind: .protocol)
        let types = result.declarations.declarations.filter {
            $0.kind == .class || $0.kind == .struct || $0.kind == .enum
        }

        return AsyncStream { continuation in
            Task {
                // Stream protocol witness edges
                for proto in protocols {
                    for edge in self.computeProtocolWitnessEdges(
                        for: proto,
                        result: result,
                        declByName: declByName
                    ) {
                        continuation.yield(edge)
                    }
                }

                // Stream type method edges
                for type in types {
                    for edge in self.computeTypeMethodEdges(for: type, result: result) {
                        continuation.yield(edge)
                    }
                }

                continuation.finish()
            }
        }
    }

    /// Compute edges for a single declaration (pure function, no actor access).
    /// This enables parallel processing of edge computation.
    private func computeEdgesForDeclaration(
        _ declaration: Declaration,
        references: ReferenceIndex,
        declByName: [String: [Declaration]],
    ) -> [DependencyEdge] {
        var edges: [DependencyEdge] = []
        let declNode = DeclarationNode(declaration: declaration)

        // Find all references within this declaration's scope
        let scopeRefs = findReferencesInScope(
            declaration: declaration,
            allRefs: references
        )

        for ref in scopeRefs {
            // Find target declarations for this reference
            let targets = findTargetDeclarations(
                for: ref,
                declarations: declByName
            )

            for target in targets {
                let targetNode = DeclarationNode(declaration: target)
                let kind = mapReferenceContextToEdgeKind(ref.context)
                edges.append(DependencyEdge(from: declNode.id, to: targetNode.id, kind: kind))
            }
        }

        // Handle type annotations
        if let typeAnnotation = declaration.typeAnnotation {
            let typeNames = extractTypeNames(from: typeAnnotation)
            for typeName in typeNames {
                if let typeDecls = declByName[typeName] {
                    for typeDecl in typeDecls {
                        let targetNode = DeclarationNode(declaration: typeDecl)
                        edges.append(DependencyEdge(from: declNode.id, to: targetNode.id, kind: .typeReference))
                    }
                }
            }
        }

        return edges
    }

    /// Find references that appear within a declaration's scope.
    private func findReferencesInScope(
        declaration: Declaration,
        allRefs: ReferenceIndex,
    ) -> [Reference] {
        // Get references in the same file within the declaration's range
        let fileRefs = allRefs.find(inFile: declaration.location.file)

        return fileRefs.filter { ref in
            // Check if the reference is within the declaration's range
            ref.location.line >= declaration.range.start.line && ref.location.line <= declaration.range.end.line
        }
    }

    /// Find declarations that a reference might be pointing to.
    private func findTargetDeclarations(
        for reference: Reference,
        declarations: [String: [Declaration]],
    ) -> [Declaration] {
        var targets: [Declaration] = []

        // Look up by identifier
        if let matches = declarations[reference.identifier] {
            targets.append(contentsOf: matches)
        }

        // Handle qualified references
        if let qualifier = reference.qualifier {
            // Try finding the qualifier too
            if let qualifierDecls = declarations[qualifier] {
                targets.append(contentsOf: qualifierDecls)
            }
        }

        return targets
    }

    /// Map reference context to dependency kind.
    private func mapReferenceContextToEdgeKind(_ context: ReferenceContext) -> DependencyKind {
        switch context {
        case .call:
            .call

        case .read,
            .write:
            .propertyAccess

        case .typeAnnotation:
            .typeReference

        case .inheritance:
            .inheritance

        case .genericConstraint:
            .genericConstraint

        case .keyPath:
            .keyPath

        case .memberAccessBase,
            .memberAccessMember:
            .propertyAccess

        case .attribute,
            .import,
            .pattern,
            .unknown:
            .typeReference
        }
    }

    /// Extract type names from a type annotation string.
    private func extractTypeNames(from typeAnnotation: String) -> [String] {
        var names: [String] = []

        // Simple extraction - split on common type separators
        let cleaned =
            typeAnnotation
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "<", with: " ")
            .replacingOccurrences(of: ">", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "->", with: " ")

        let parts = cleaned.split(separator: " ")

        for part in parts {
            let name = String(part).trimmingCharacters(in: .whitespaces)

            // Skip keywords and basic types
            if !name.isEmpty,
                name.first?.isUppercase == true,
                !isBuiltInType(name)
            {
                names.append(name)
            }
        }

        return names
    }

    /// Check if a type name is a built-in Swift type.
    private func isBuiltInType(_ name: String) -> Bool {
        let builtIns: Set<String> = [
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "Float16", "Float80",
            "Bool", "String", "Character",
            "Array", "Dictionary", "Set", "Optional",
            "Any", "AnyObject", "AnyClass",
            "Void", "Never",
            "Error", "Equatable", "Hashable", "Comparable",
            "Codable", "Encodable", "Decodable",
            "Sendable", "Identifiable",
        ]
        return builtIns.contains(name)
    }

    /// Add edges for protocol witness relationships using parallel processing.
    private func addProtocolWitnessEdgesParallel(
        graph: ReachabilityGraph,
        result: AnalysisResult,
        declByName: [String: [Declaration]],
    ) async {
        let protocols = result.declarations.find(kind: .protocol)
        let types = result.declarations.declarations.filter {
            $0.kind == .class || $0.kind == .struct || $0.kind == .enum
        }

        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount

        // Parallelize protocol witness edge computation
        let protoEdges = await ParallelProcessor.compactMap(
            protocols,
            maxConcurrency: maxConcurrency
        ) { proto -> [DependencyEdge]? in
            let edges = self.computeProtocolWitnessEdges(
                for: proto,
                result: result,
                declByName: declByName
            )
            return edges.isEmpty ? nil : edges
        }

        // Parallelize type method edge computation
        let typeEdges = await ParallelProcessor.compactMap(
            types,
            maxConcurrency: maxConcurrency
        ) { type -> [DependencyEdge]? in
            let edges = self.computeTypeMethodEdges(for: type, result: result)
            return edges.isEmpty ? nil : edges
        }

        // Batch insert all edges (single actor call)
        let allEdges = protoEdges.flatMap { $0 } + typeEdges.flatMap { $0 }
        await graph.addEdges(allEdges)
    }

    /// Compute protocol witness edges for a single protocol (pure function).
    private func computeProtocolWitnessEdges(
        for proto: Declaration,
        result: AnalysisResult,
        declByName: [String: [Declaration]],
    ) -> [DependencyEdge] {
        var edges: [DependencyEdge] = []

        // Get methods declared in the protocol (approximate by scope)
        let protoMethods = result.declarations.declarations.filter { decl in
            (decl.kind == .function || decl.kind == .method) && decl.scope.id.contains(proto.name)
        }

        for protoMethod in protoMethods {
            // Find matching implementations in types
            if let implementations = declByName[protoMethod.name] {
                for impl in implementations {
                    // Check if this is likely a protocol implementation
                    // (same kind, not in protocol itself)
                    if impl.kind == protoMethod.kind,
                        !impl.scope.id.contains(proto.name)
                    {
                        let protoNode = DeclarationNode(declaration: protoMethod)
                        let implNode = DeclarationNode(declaration: impl)
                        edges.append(DependencyEdge(from: protoNode.id, to: implNode.id, kind: .typeReference))
                    }
                }
            }
        }

        return edges
    }

    /// Compute type method edges for a single type (pure function).
    private func computeTypeMethodEdges(
        for type: Declaration,
        result: AnalysisResult,
    ) -> [DependencyEdge] {
        var edges: [DependencyEdge] = []
        let typeNode = DeclarationNode(declaration: type)

        // Find methods in this type's scope
        let typeMethods = result.declarations.declarations.filter { decl in
            (decl.kind == .function || decl.kind == .method) && decl.scope.id.contains(type.name)
        }

        for method in typeMethods {
            let methodNode = DeclarationNode(declaration: method)
            edges.append(DependencyEdge(from: typeNode.id, to: methodNode.id, kind: .call))
        }

        return edges
    }
}

// MARK: - DependencyExtractionConfiguration

/// Configuration for dependency extraction.
public struct DependencyExtractionConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        treatPublicAsRoot: Bool = true,
        treatObjcAsRoot: Bool = true,
        treatTestsAsRoot: Bool = true,
        treatProtocolRequirementsAsRoot: Bool = true,
        treatSwiftUIViewsAsRoot: Bool = true,
        treatSwiftUIPropertyWrappersAsRoot: Bool = true,
        treatPreviewProvidersAsRoot: Bool = true,
        trackProtocolWitnesses: Bool = true,
        trackClosureCaptures: Bool = true,
    ) {
        self.treatPublicAsRoot = treatPublicAsRoot
        self.treatObjcAsRoot = treatObjcAsRoot
        self.treatTestsAsRoot = treatTestsAsRoot
        self.treatProtocolRequirementsAsRoot = treatProtocolRequirementsAsRoot
        self.treatSwiftUIViewsAsRoot = treatSwiftUIViewsAsRoot
        self.treatSwiftUIPropertyWrappersAsRoot = treatSwiftUIPropertyWrappersAsRoot
        self.treatPreviewProvidersAsRoot = treatPreviewProvidersAsRoot
        self.trackProtocolWitnesses = trackProtocolWitnesses
        self.trackClosureCaptures = trackClosureCaptures
    }

    // MARK: Public

    /// Default configuration.
    public static let `default` = Self()

    /// Strict configuration for finding more unused code.
    public static let strict = Self(
        treatPublicAsRoot: false,
        treatObjcAsRoot: true,
        treatTestsAsRoot: true,
        treatProtocolRequirementsAsRoot: true,
        treatSwiftUIViewsAsRoot: true,
        treatSwiftUIPropertyWrappersAsRoot: true,
        treatPreviewProvidersAsRoot: false,
        trackProtocolWitnesses: true,
        trackClosureCaptures: true,
    )

    /// Treat public/open declarations as roots.
    public var treatPublicAsRoot: Bool

    /// Treat @objc declarations as roots.
    public var treatObjcAsRoot: Bool

    /// Treat test methods as roots.
    public var treatTestsAsRoot: Bool

    /// Treat protocol requirements as roots.
    public var treatProtocolRequirementsAsRoot: Bool

    /// Treat SwiftUI Views as roots.
    public var treatSwiftUIViewsAsRoot: Bool

    /// Treat SwiftUI property wrappers as roots.
    public var treatSwiftUIPropertyWrappersAsRoot: Bool

    /// Treat PreviewProviders as roots.
    public var treatPreviewProvidersAsRoot: Bool

    /// Track protocol witness relationships.
    public var trackProtocolWitnesses: Bool

    /// Track closure captures.
    public var trackClosureCaptures: Bool
}

// MARK: - ReachabilityBasedDetector

/// Unused code detector using reachability analysis.
public struct ReachabilityBasedDetector: Sendable {
    // MARK: Lifecycle

    public init(
        configuration: UnusedCodeConfiguration = .default,
        extractionConfiguration: DependencyExtractionConfiguration = .default,
    ) {
        self.configuration = configuration
        self.extractionConfiguration = extractionConfiguration
    }

    // MARK: Public

    /// Configuration.
    public let configuration: UnusedCodeConfiguration

    /// Dependency extraction configuration.
    public let extractionConfiguration: DependencyExtractionConfiguration

    /// Detect unused code using reachability analysis.
    public func detect(in result: AnalysisResult) async -> [UnusedCode] {
        // Build the reachability graph
        let extractor = DependencyExtractor(configuration: extractionConfiguration)
        let graph = await extractor.buildGraph(from: result)

        // Get unreachable declarations using sequential or parallel BFS
        let unreachable: [DeclarationNode]
        if configuration.useParallelBFS {
            unreachable = await graph.computeUnreachableParallel()
        } else {
            unreachable = await graph.computeUnreachable()
        }

        // Convert to UnusedCode
        return unreachable.compactMap { node -> UnusedCode? in
            let declaration = node.declaration

            // Apply configuration filters
            if !shouldReport(declaration) {
                return nil
            }

            // Skip if below minimum confidence
            let confidence = declaration.unusedConfidence
            if confidence < configuration.minimumConfidence {
                return nil
            }

            return UnusedCode(
                declaration: declaration,
                reason: .neverReferenced,
                confidence: confidence,
                suggestion: "Unreachable from any entry point - consider removing '\(declaration.name)'"
            )
        }
    }

    /// Generate a reachability report.
    public func generateReport(for result: AnalysisResult) async -> ReachabilityReport {
        let extractor = DependencyExtractor(configuration: extractionConfiguration)
        let graph = await extractor.buildGraph(from: result)
        return await graph.generateReport()
    }

    // MARK: Private

    /// Check if a declaration should be reported based on configuration.
    private func shouldReport(_ declaration: Declaration) -> Bool {
        switch declaration.kind {
        case .constant,
            .variable:
            configuration.detectVariables

        case .function,
            .method:
            configuration.detectFunctions

        case .class,
            .enum,
            .protocol,
            .struct:
            configuration.detectTypes

        case .parameter:
            configuration.detectParameters

        case .import:
            configuration.detectImports

        default:
            true
        }
    }
}
