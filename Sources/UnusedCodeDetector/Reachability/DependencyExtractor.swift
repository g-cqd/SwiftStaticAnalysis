//
//  DependencyExtractor.swift
//  SwiftStaticAnalysis
//
//  Extracts dependencies between declarations to build the reachability graph.
//

import Foundation
import SwiftStaticAnalysisCore

// MARK: - DependencyExtractor

/// Extracts dependencies from analysis results to build a reachability graph.
public struct DependencyExtractor: Sendable {
    // MARK: Lifecycle

    public init(configuration: DependencyExtractionConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: Public

    /// Configuration for extraction.
    public let configuration: DependencyExtractionConfiguration

    /// Build a reachability graph from analysis results.
    public func buildGraph(from result: AnalysisResult) -> ReachabilityGraph {
        let graph = ReachabilityGraph()

        // Add all declarations as nodes and detect roots
        let rootConfig = RootDetectionConfiguration(
            treatPublicAsRoot: configuration.treatPublicAsRoot,
            treatObjcAsRoot: configuration.treatObjcAsRoot,
            treatTestsAsRoot: configuration.treatTestsAsRoot,
            treatProtocolRequirementsAsRoot: configuration.treatProtocolRequirementsAsRoot,
        )

        graph.detectRoots(
            declarations: result.declarations.declarations,
            references: result.references,
            configuration: rootConfig,
        )

        // Build edges based on references
        buildEdges(graph: graph, result: result)

        return graph
    }

    // MARK: Private

    /// Build edges between declarations based on references.
    private func buildEdges(graph: ReachabilityGraph, result: AnalysisResult) {
        let declarations = result.declarations
        let references = result.references

        // Create a lookup from name to declarations
        var declByName: [String: [Declaration]] = [:]
        for decl in declarations.declarations {
            declByName[decl.name, default: []].append(decl)
        }

        // For each declaration, find its references and create edges
        for declaration in declarations.declarations {
            let declNode = DeclarationNode(declaration: declaration)

            // Find all references within this declaration's scope
            let scopeRefs = findReferencesInScope(
                declaration: declaration,
                allRefs: references,
            )

            for ref in scopeRefs {
                // Find target declarations for this reference
                let targets = findTargetDeclarations(
                    for: ref,
                    declarations: declByName,
                )

                for target in targets {
                    let targetNode = DeclarationNode(declaration: target)
                    let kind = mapReferenceContextToEdgeKind(ref.context)
                    graph.addEdge(from: declNode.id, to: targetNode.id, kind: kind)
                }
            }

            // Handle type annotations
            if let typeAnnotation = declaration.typeAnnotation {
                let typeNames = extractTypeNames(from: typeAnnotation)
                for typeName in typeNames {
                    if let typeDecls = declByName[typeName] {
                        for typeDecl in typeDecls {
                            let targetNode = DeclarationNode(declaration: typeDecl)
                            graph.addEdge(from: declNode.id, to: targetNode.id, kind: .typeReference)
                        }
                    }
                }
            }

            // Handle inheritance/conformance (for types)
            addInheritanceEdges(
                for: declaration,
                graph: graph,
                declarations: declByName,
            )
        }

        // Handle protocol witnesses
        if configuration.trackProtocolWitnesses {
            addProtocolWitnessEdges(graph: graph, result: result, declByName: declByName)
        }
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

    /// Add edges for inheritance and protocol conformance.
    private func addInheritanceEdges(
        for declaration: Declaration,
        graph: ReachabilityGraph,
        declarations: [String: [Declaration]],
    ) {
        // This would ideally use inheritance info from the syntax tree
        // For now, we rely on references with inheritance context
    }

    /// Add edges for protocol witness relationships.
    private func addProtocolWitnessEdges(
        graph: ReachabilityGraph,
        result: AnalysisResult,
        declByName: [String: [Declaration]],
    ) {
        // Find all protocols
        let protocols = result.declarations.find(kind: .protocol)

        // Find all types that might conform to protocols
        let types = result.declarations.declarations.filter {
            $0.kind == .class || $0.kind == .struct || $0.kind == .enum
        }

        // This is a simplified version - ideally we'd have actual conformance info
        // For now, we mark protocol methods as potentially witnessing if a type
        // has a method with the same name

        for proto in protocols {
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
                            // Add edge from protocol method to implementation
                            let protoNode = DeclarationNode(declaration: protoMethod)
                            let implNode = DeclarationNode(declaration: impl)

                            // Implementations are reachable if protocol is reachable
                            graph.addEdge(from: protoNode.id, to: implNode.id, kind: .typeReference)
                        }
                    }
                }
            }
        }

        // Mark protocol requirements as reachable from conforming types
        for type in types {
            // If a type exists, its protocol implementations should be reachable
            let typeNode = DeclarationNode(declaration: type)

            // Find methods in this type's scope
            let typeMethods = result.declarations.declarations.filter { decl in
                (decl.kind == .function || decl.kind == .method) && decl.scope.id.contains(type.name)
            }

            for method in typeMethods {
                let methodNode = DeclarationNode(declaration: method)
                graph.addEdge(from: typeNode.id, to: methodNode.id, kind: .call)
            }
        }
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
        trackProtocolWitnesses: Bool = true,
        trackClosureCaptures: Bool = true,
    ) {
        self.treatPublicAsRoot = treatPublicAsRoot
        self.treatObjcAsRoot = treatObjcAsRoot
        self.treatTestsAsRoot = treatTestsAsRoot
        self.treatProtocolRequirementsAsRoot = treatProtocolRequirementsAsRoot
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
    public func detect(in result: AnalysisResult) -> [UnusedCode] {
        // Build the reachability graph
        let extractor = DependencyExtractor(configuration: extractionConfiguration)
        let graph = extractor.buildGraph(from: result)

        // Get unreachable declarations
        let unreachable = graph.computeUnreachable()

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
                suggestion: "Unreachable from any entry point - consider removing '\(declaration.name)'",
            )
        }
    }

    /// Generate a reachability report.
    public func generateReport(for result: AnalysisResult) -> ReachabilityReport {
        let extractor = DependencyExtractor(configuration: extractionConfiguration)
        let graph = extractor.buildGraph(from: result)
        return graph.generateReport()
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
