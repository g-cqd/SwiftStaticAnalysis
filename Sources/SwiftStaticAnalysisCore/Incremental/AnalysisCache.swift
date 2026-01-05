//  AnalysisCache.swift
//  SwiftStaticAnalysis
//  MIT License

import Algorithms
import Foundation

// MARK: - CacheData

/// Codable structure for persisting cache to disk.
public struct CacheData: Codable, Sendable {
    // MARK: Lifecycle

    public init(
        fileStates: [String: FileState],
        declarations: [String: [CachedDeclaration]],
        references: [String: [CachedReference]],
    ) {
        version = Self.formatVersion
        self.fileStates = fileStates
        self.declarations = declarations
        self.references = references
        timestamp = Date()
    }

    // MARK: Public

    /// Cache format version for migration support.
    public static let formatVersion = 1

    /// Format version of this cache data.
    public let version: Int

    /// File states for change detection.
    public let fileStates: [String: FileState]

    /// Cached declarations by file.
    public let declarations: [String: [CachedDeclaration]]

    /// Cached references by file.
    public let references: [String: [CachedReference]]

    /// Timestamp when cache was created.
    public let timestamp: Date
}

// MARK: - CachedDeclaration

/// Lightweight declaration data for caching.
public struct CachedDeclaration: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(
        name: String,
        kind: String,
        file: String,
        line: Int,
        column: Int,
        offset: Int,
        accessLevel: String,
        modifiers: UInt32,
        scopeID: String,
        typeAnnotation: String?,
        documentation: String?,
        conformances: [String],
    ) {
        self.name = name
        self.kind = kind
        self.file = file
        self.line = line
        self.column = column
        self.offset = offset
        self.accessLevel = accessLevel
        self.modifiers = modifiers
        self.scopeID = scopeID
        self.typeAnnotation = typeAnnotation
        self.documentation = documentation
        self.conformances = conformances
    }

    /// Create from a Declaration.
    public init(from declaration: Declaration) {
        name = declaration.name
        kind = declaration.kind.rawValue
        file = declaration.location.file
        line = declaration.location.line
        column = declaration.location.column
        offset = declaration.location.offset
        accessLevel = declaration.accessLevel.rawValue
        modifiers = declaration.modifiers.rawValue
        scopeID = declaration.scope.id
        typeAnnotation = declaration.typeAnnotation
        documentation = declaration.documentation
        conformances = declaration.conformances
    }

    // MARK: Public

    public let name: String
    public let kind: String
    public let file: String
    public let line: Int
    public let column: Int
    public let offset: Int
    public let accessLevel: String
    public let modifiers: UInt32
    public let scopeID: String
    public let typeAnnotation: String?
    public let documentation: String?
    public let conformances: [String]
}

// MARK: - CachedReference

/// Lightweight reference data for caching.
public struct CachedReference: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(
        identifier: String,
        file: String,
        line: Int,
        column: Int,
        offset: Int,
        scopeID: String,
        context: String,
        isQualified: Bool,
        qualifier: String?,
    ) {
        self.identifier = identifier
        self.file = file
        self.line = line
        self.column = column
        self.offset = offset
        self.scopeID = scopeID
        self.context = context
        self.isQualified = isQualified
        self.qualifier = qualifier
    }

    /// Create from a Reference.
    public init(from reference: Reference) {
        identifier = reference.identifier
        file = reference.location.file
        line = reference.location.line
        column = reference.location.column
        offset = reference.location.offset
        scopeID = reference.scope.id
        context = reference.context.rawValue
        isQualified = reference.isQualified
        qualifier = reference.qualifier
    }

    // MARK: Public

    public let identifier: String
    public let file: String
    public let line: Int
    public let column: Int
    public let offset: Int
    public let scopeID: String
    public let context: String
    public let isQualified: Bool
    public let qualifier: String?
}

// MARK: - AnalysisCache

/// Actor-based persistent cache for analysis results.
public actor AnalysisCache {
    // MARK: Lifecycle

    // MARK: - Initialization

    /// Create a cache with the specified cache directory.
    ///
    /// - Parameter cacheDirectory: Directory to store cache files.
    ///   Defaults to a `.swiftanalysis` directory in the current working directory.
    public init(cacheDirectory: URL? = nil) {
        let directory =
            cacheDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".swiftanalysis")
        cacheURL = directory.appendingPathComponent("analysis_cache.json")
    }

    /// Create a cache at a specific file path.
    ///
    /// - Parameter cacheFile: Path to the cache file.
    public init(cacheFile: URL) {
        cacheURL = cacheFile
    }

    // MARK: Public

    // MARK: - Statistics

    /// Cache statistics.
    public struct Statistics: Sendable {
        public let fileCount: Int
        public let declarationCount: Int
        public let referenceCount: Int
        public let cacheSize: Int64?
    }

    // MARK: - Persistence

    /// Load cache from disk.
    ///
    /// - Throws: Error if cache file exists but can't be read or decoded.
    public func load() async throws {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            isLoaded = true
            return
        }

        let data = try Data(contentsOf: cacheURL)
        let cached = try JSONDecoder().decode(CacheData.self, from: data)

        // Check version compatibility
        guard cached.version == CacheData.formatVersion else {
            // Incompatible version, start fresh
            isLoaded = true
            return
        }

        fileStates = cached.fileStates
        declarations = cached.declarations
        references = cached.references
        isDirty = false
        isLoaded = true
    }

    /// Save cache to disk.
    ///
    /// - Throws: Error if cache can't be written.
    public func save() async throws {
        guard isDirty else { return }

        let cacheData = CacheData(
            fileStates: fileStates,
            declarations: declarations,
            references: references,
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cacheData)

        // Ensure directory exists
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try data.write(to: cacheURL)
        isDirty = false
    }

    /// Clear all cached data.
    public func clear() {
        fileStates.removeAll()
        declarations.removeAll()
        references.removeAll()
        isDirty = true
    }

    /// Delete cache file from disk.
    public func delete() throws {
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
        clear()
        isDirty = false
    }

    // MARK: - File States

    /// Get all file states.
    public func getFileStates() -> [String: FileState] {
        fileStates
    }

    /// Get file state for a specific path.
    ///
    /// - Parameter path: File path.
    /// - Returns: File state, or nil if not cached.
    public func getFileState(for path: String) -> FileState? {
        fileStates[path]
    }

    /// Update file state.
    ///
    /// - Parameters:
    ///   - state: New file state.
    ///   - path: File path.
    public func setFileState(_ state: FileState, for path: String) {
        fileStates[path] = state
        isDirty = true
    }

    /// Remove file state.
    ///
    /// - Parameter path: File path.
    public func removeFileState(for path: String) {
        fileStates.removeValue(forKey: path)
        isDirty = true
    }

    // MARK: - Declarations

    /// Get cached declarations for a file.
    ///
    /// - Parameter file: File path.
    /// - Returns: Array of cached declarations.
    public func getDeclarations(for file: String) -> [CachedDeclaration] {
        declarations[file] ?? []
    }

    /// Get all cached declarations.
    public func getAllDeclarations() -> [CachedDeclaration] {
        declarations.values.flatMap(\.self)
    }

    /// Set declarations for a file.
    ///
    /// - Parameters:
    ///   - decls: Declarations to cache.
    ///   - file: File path.
    public func setDeclarations(_ decls: [CachedDeclaration], for file: String) {
        declarations[file] = decls
        isDirty = true
    }

    /// Set declarations from Declaration objects.
    ///
    /// - Parameters:
    ///   - decls: Declaration objects.
    ///   - file: File path.
    public func setDeclarations(_ decls: [Declaration], for file: String) {
        declarations[file] = decls.map { CachedDeclaration(from: $0) }
        isDirty = true
    }

    /// Remove declarations for a file.
    ///
    /// - Parameter file: File path.
    public func removeDeclarations(for file: String) {
        declarations.removeValue(forKey: file)
        isDirty = true
    }

    // MARK: - References

    /// Get cached references for a file.
    ///
    /// - Parameter file: File path.
    /// - Returns: Array of cached references.
    public func getReferences(for file: String) -> [CachedReference] {
        references[file] ?? []
    }

    /// Get all cached references.
    public func getAllReferences() -> [CachedReference] {
        references.values.flatMap(\.self)
    }

    /// Set references for a file.
    ///
    /// - Parameters:
    ///   - refs: References to cache.
    ///   - file: File path.
    public func setReferences(_ refs: [CachedReference], for file: String) {
        references[file] = refs
        isDirty = true
    }

    /// Set references from Reference objects.
    ///
    /// - Parameters:
    ///   - refs: Reference objects.
    ///   - file: File path.
    public func setReferences(_ refs: [Reference], for file: String) {
        references[file] = refs.map { CachedReference(from: $0) }
        isDirty = true
    }

    /// Remove references for a file.
    ///
    /// - Parameter file: File path.
    public func removeReferences(for file: String) {
        references.removeValue(forKey: file)
        isDirty = true
    }

    // MARK: - Bulk Operations

    /// Invalidate cache for changed files.
    ///
    /// - Parameter changes: Change detection result.
    public func invalidate(for changes: ChangeDetectionResult) {
        // Remove data for modified and deleted files
        for file in chain(changes.modifiedFiles, changes.deletedFiles) {
            removeFileState(for: file)
            removeDeclarations(for: file)
            removeReferences(for: file)
        }
    }

    /// Update cache with new analysis results.
    ///
    /// - Parameters:
    ///   - file: File path.
    ///   - state: Current file state.
    ///   - decls: Declarations found.
    ///   - refs: References found.
    public func update(
        file: String,
        state: FileState,
        declarations decls: [Declaration],
        references refs: [Reference],
    ) {
        setFileState(state, for: file)
        setDeclarations(decls, for: file)
        setReferences(refs, for: file)
    }

    /// Get cache statistics.
    public func statistics() -> Statistics {
        let cacheSize: Int64? =
            if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
                let size = attrs[.size] as? Int64
            {
                size
            } else {
                nil
            }

        return Statistics(
            fileCount: fileStates.count,
            declarationCount: declarations.values.reduce(0) { $0 + $1.count },
            referenceCount: references.values.reduce(0) { $0 + $1.count },
            cacheSize: cacheSize,
        )
    }

    // MARK: Private

    /// Location of the cache file.
    private let cacheURL: URL

    /// File states for change detection.
    private var fileStates: [String: FileState] = [:]

    /// Cached declarations by file.
    private var declarations: [String: [CachedDeclaration]] = [:]

    /// Cached references by file.
    private var references: [String: [CachedReference]] = [:]

    /// Whether the cache has unsaved changes.
    private var isDirty: Bool = false

    /// Whether the cache has been loaded.
    private var isLoaded: Bool = false
}
