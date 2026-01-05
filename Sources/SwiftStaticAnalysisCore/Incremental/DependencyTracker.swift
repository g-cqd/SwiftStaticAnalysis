//  DependencyTracker.swift
//  SwiftStaticAnalysis
//  MIT License

import Collections
import Foundation

// MARK: - DependencyType

/// Types of dependencies between files.
/// Exhaustive coverage for dependency tracking. // swa:ignore-unused-cases
public enum DependencyType: String, Codable, Sendable {
    /// Import dependency (import Module)
    case importDependency

    /// Type reference (uses a type defined in another file)
    case typeReference

    /// Function call (calls a function defined in another file)
    case functionCall

    /// Protocol conformance (conforms to protocol from another file)
    case protocolConformance

    /// Inheritance (inherits from class in another file)
    case inheritance

    /// Extension (extends type from another file)
    case extensionDependency
}

// MARK: - FileDependency

/// Represents a dependency from one file to another.
public struct FileDependency: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(
        dependentFile: String,
        dependencyFile: String,
        type: DependencyType,
        symbolName: String? = nil,
    ) {
        self.dependentFile = dependentFile
        self.dependencyFile = dependencyFile
        self.type = type
        self.symbolName = symbolName
    }

    // MARK: Public

    /// The file that has the dependency.
    public let dependentFile: String

    /// The file being depended upon.
    public let dependencyFile: String

    /// Type of dependency.
    public let type: DependencyType

    /// Name of the symbol creating the dependency (type name, function name, etc.)
    public let symbolName: String?
}

// MARK: - DependencyGraph

/// Graph of file dependencies for efficient traversal.
public struct DependencyGraph: Codable, Sendable {
    // MARK: Lifecycle

    public init() {
        dependencies = [:]
        dependents = [:]
        details = []
    }

    // MARK: Public

    /// Forward edges: file -> files it depends on.
    public var dependencies: [String: Set<String>]

    /// Reverse edges: file -> files that depend on it.
    public var dependents: [String: Set<String>]

    /// Detailed dependency information.
    public var details: [FileDependency]

    /// Add a dependency.
    public mutating func addDependency(_ dependency: FileDependency) {
        dependencies[dependency.dependentFile, default: []].insert(dependency.dependencyFile)
        dependents[dependency.dependencyFile, default: []].insert(dependency.dependentFile)
        details.append(dependency)
    }

    /// Remove all dependencies for a file.
    public mutating func removeDependencies(for file: String) {
        // Remove forward edges
        if let deps = dependencies[file] {
            for dep in deps {
                dependents[dep]?.remove(file)
            }
        }
        dependencies.removeValue(forKey: file)

        // Remove details
        details.removeAll { $0.dependentFile == file }
    }

    /// Remove file as a dependency target (when file is deleted).
    public mutating func removeDependencyTarget(_ file: String) {
        // Remove reverse edges
        if let deps = dependents[file] {
            for dep in deps {
                dependencies[dep]?.remove(file)
            }
        }
        dependents.removeValue(forKey: file)

        // Remove details
        details.removeAll { $0.dependencyFile == file }
    }

    /// Get all files that directly depend on the given file.
    public func getDirectDependents(of file: String) -> Set<String> {
        dependents[file] ?? []
    }

    /// Get all files that the given file depends on.
    public func getDirectDependencies(of file: String) -> Set<String> {
        dependencies[file] ?? []
    }

    /// Get all files transitively affected by changes to the given files.
    /// Uses BFS to find all transitive dependents.
    public func getAffectedFiles(changedFiles: Set<String>) -> Set<String> {
        var affected = Set<String>()
        var queue = Deque(changedFiles)  // O(1) pop from front
        var visited = changedFiles

        while let file = queue.popFirst() {  // O(1) instead of O(n)
            affected.insert(file)

            for dependent in getDirectDependents(of: file) where !visited.contains(dependent) {
                visited.insert(dependent)
                queue.append(dependent)
            }
        }

        return affected
    }
}

// MARK: - DependencyTracker

/// Tracks and manages file dependencies.
public actor DependencyTracker {
    // MARK: Lifecycle

    // MARK: - Initialization

    public init(cacheDirectory: URL? = nil) {
        graph = DependencyGraph()

        if let directory = cacheDirectory {
            cacheURL = directory.appendingPathComponent("dependencies.json")
        } else {
            cacheURL = nil
        }
    }

    // MARK: Public

    // MARK: - Statistics

    /// Dependency statistics.
    public struct Statistics: Sendable {
        public let fileCount: Int
        public let dependencyCount: Int
        public let averageDependencies: Double
        public let maxDependencies: Int
        public let maxDependents: Int
    }

    // MARK: - Persistence

    /// Load dependency graph from disk.
    public func load() async throws {
        guard let url = cacheURL,
            FileManager.default.fileExists(atPath: url.path)
        else {
            return
        }

        let data = try Data(contentsOf: url)
        graph = try JSONDecoder().decode(DependencyGraph.self, from: data)
        isDirty = false
    }

    /// Save dependency graph to disk.
    public func save() async throws {
        guard isDirty, let url = cacheURL else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(graph)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try data.write(to: url)
        isDirty = false
    }

    // MARK: - Dependency Management

    /// Add a dependency.
    public func addDependency(_ dependency: FileDependency) {
        graph.addDependency(dependency)
        isDirty = true
    }

    /// Add multiple dependencies.
    public func addDependencies(_ dependencies: [FileDependency]) {
        for dependency in dependencies {
            graph.addDependency(dependency)
        }
        if !dependencies.isEmpty {
            isDirty = true
        }
    }

    /// Update dependencies for a file (removes old, adds new).
    public func updateDependencies(for file: String, newDependencies: [FileDependency]) {
        graph.removeDependencies(for: file)
        for dependency in newDependencies {
            graph.addDependency(dependency)
        }
        isDirty = true
    }

    /// Remove all dependencies for a file.
    public func removeDependencies(for file: String) {
        graph.removeDependencies(for: file)
        isDirty = true
    }

    /// Remove a file completely (as both source and target of dependencies).
    public func removeFile(_ file: String) {
        graph.removeDependencies(for: file)
        graph.removeDependencyTarget(file)
        isDirty = true
    }

    /// Clear all dependencies.
    public func clear() {
        graph = DependencyGraph()
        isDirty = true
    }

    // MARK: - Queries

    /// Get files directly dependent on the given file.
    public func getDirectDependents(of file: String) -> Set<String> {
        graph.getDirectDependents(of: file)
    }

    /// Get files the given file depends on.
    public func getDirectDependencies(of file: String) -> Set<String> {
        graph.getDirectDependencies(of: file)
    }

    /// Get all files transitively affected by changes.
    public func getAffectedFiles(changedFiles: Set<String>) -> Set<String> {
        graph.getAffectedFiles(changedFiles: changedFiles)
    }

    /// Get the current dependency graph (for inspection).
    public func getGraph() -> DependencyGraph {
        graph
    }

    /// Get dependency statistics.
    public func statistics() -> Statistics {
        let fileCount = Set(graph.dependencies.keys).union(graph.dependents.keys).count
        let dependencyCount = graph.details.count
        let avgDeps =
            fileCount > 0
            ? Double(graph.dependencies.values.reduce(0) { $0 + $1.count }) / Double(fileCount)
            : 0
        let maxDeps = graph.dependencies.values.map(\.count).max() ?? 0
        let maxDependents = graph.dependents.values.map(\.count).max() ?? 0

        return Statistics(
            fileCount: fileCount,
            dependencyCount: dependencyCount,
            averageDependencies: avgDeps,
            maxDependencies: maxDeps,
            maxDependents: maxDependents,
        )
    }

    // MARK: Private

    /// The dependency graph.
    private var graph: DependencyGraph

    /// Cache URL for persistence.
    private let cacheURL: URL?

    /// Whether the graph has unsaved changes.
    private var isDirty: Bool = false
}

// MARK: - DependencyExtractor

/// Extracts dependencies from analysis results.
public struct DependencyExtractor: Sendable {
    // MARK: Lifecycle

    public init(declarationIndex: DeclarationIndex) {
        self.declarationIndex = declarationIndex
    }

    // MARK: Public

    /// Extract dependencies from references in a file.
    ///
    /// - Parameters:
    ///   - references: References found in the file.
    ///   - sourceFile: The file containing the references.
    /// - Returns: Dependencies to other files.
    public func extractDependencies(
        from references: [Reference],
        in sourceFile: String,
    ) -> [FileDependency] {
        var dependencies: [FileDependency] = []

        for reference in references {
            // Skip references not in the source file
            guard reference.location.file == sourceFile else { continue }

            // Find where this symbol is defined
            let definitions = declarationIndex.find(name: reference.identifier)
            for definition in definitions {
                // Skip if defined in same file
                guard definition.location.file != sourceFile else { continue }

                let depType: DependencyType =
                    switch reference.context {
                    case .genericConstraint,
                        .typeAnnotation:
                        .typeReference

                    case .call:
                        .functionCall

                    case .inheritance:
                        // Check if it's a protocol or class
                        if definition.kind == .protocol {
                            .protocolConformance
                        } else {
                            .inheritance
                        }

                    default:
                        .typeReference
                    }

                dependencies.append(
                    FileDependency(
                        dependentFile: sourceFile,
                        dependencyFile: definition.location.file,
                        type: depType,
                        symbolName: reference.identifier,
                    ))
            }
        }

        // Deduplicate
        return Array(Set(dependencies))
    }

    /// Extract import dependencies from declarations.
    ///
    /// - Parameters:
    ///   - declarations: Declarations in the file (including imports).
    ///   - sourceFile: The file containing the declarations.
    ///   - moduleToFiles: Mapping from module names to their files.
    /// - Returns: Import dependencies.
    public func extractImportDependencies(
        from declarations: [Declaration],
        in sourceFile: String,
        moduleToFiles: [String: [String]],
    ) -> [FileDependency] {
        var dependencies: [FileDependency] = []

        for declaration in declarations {
            guard declaration.kind == .import else { continue }

            // If we know files for this module, add dependencies
            if let files = moduleToFiles[declaration.name] {
                for file in files where file != sourceFile {
                    dependencies.append(
                        FileDependency(
                            dependentFile: sourceFile,
                            dependencyFile: file,
                            type: .importDependency,
                            symbolName: declaration.name,
                        ))
                }
            }
        }

        return dependencies
    }

    // MARK: Private

    /// Declaration index for looking up symbol locations.
    private let declarationIndex: DeclarationIndex
}
