//  IndexStoreReader.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import IndexStoreDB

// MARK: - IndexStoreError

/// Errors that can occur when reading the index store.
/// Exhaustive error cases for comprehensive error handling. // swa:ignore-unused-cases
public enum IndexStoreError: Error, Sendable {
    case indexStoreNotFound(path: String)
    case failedToOpenDatabase(underlying: Error)
    case invalidConfiguration
    case noIndexStoreForProject
    /// The sibling `IndexDatabase/` directory does not exist and the caller
    /// did not opt into creation (e.g. the MCP server, which must not
    /// perform filesystem-write side effects from attacker-controlled
    /// argument paths). The CLI auto-discovery path opts in via
    /// `IndexStoreReader.init(allowsDirectoryCreation: true)`.
    case databaseDirectoryMissing(String)
    /// `libIndexStore.dylib` could not be located at any trusted path
    /// (Xcode toolchain, command-line tools, xcrun-resolved toolchain). The
    /// previous behaviour silently fell back to an empty string and let the
    /// C++ layer crash; now surfaced as a typed Swift error.
    case dylibNotFound
}

// MARK: - IndexedSymbol

/// Information about a symbol from the index store.
public struct IndexedSymbol: Sendable {
    // MARK: Lifecycle

    public init(usr: String, name: String, kind: IndexedSymbolKind, isSystem: Bool) {
        self.usr = usr
        self.name = name
        self.kind = kind
        self.isSystem = isSystem
    }

    // MARK: Public

    /// The symbol's USR (Unique Symbol Reference).
    public let usr: String

    /// The symbol name.
    public let name: String

    /// The kind of symbol.
    public let kind: IndexedSymbolKind

    /// Whether this is a system symbol.
    public let isSystem: Bool
}

// MARK: - IndexedSymbolKind

/// Kinds of symbols in the index store.
/// Exhaustive mapping from IndexStoreDB symbol kinds. // swa:ignore-unused-cases
public enum IndexedSymbolKind: String, Sendable {
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case `extension`
    case function
    case method
    case property
    case variable
    case parameter
    case `typealias`
    case module
    case unknown

    // MARK: Lifecycle

    /// Convert from IndexStoreDB's IndexSymbolKind.
    public init(from kind: IndexSymbolKind) {
        switch kind {
        case .class: self = .class
        case .struct: self = .struct
        case .enum: self = .enum
        case .protocol: self = .protocol
        case .extension: self = .extension
        case .classMethod,
            .function,
            .instanceMethod,
            .staticMethod:
            self = .function
        case .classProperty,
            .instanceProperty,
            .staticProperty:
            self = .property
        case .variable:
            self = .variable
        case .parameter:
            self = .parameter
        case .typealias:
            self = .typealias
        case .module:
            self = .module
        default:
            self = .unknown
        }
    }

    // MARK: Public

    /// Convert IndexedSymbolKind to DeclarationKind.
    public func toDeclarationKind() -> DeclarationKind {
        switch self {
        case .class: .class
        case .struct: .struct
        case .enum: .enum
        case .protocol: .protocol
        case .extension: .extension
        case .function,
            .method:
            .function
        case .property,
            .variable:
            .variable
        case .parameter: .parameter
        case .typealias: .typealias
        case .module: .import
        case .unknown: .variable
        }
    }
}

// MARK: - IndexedOccurrence

/// Information about where a symbol occurs in the codebase.
public struct IndexedOccurrence: Sendable {
    // MARK: Lifecycle

    public init(
        symbol: IndexedSymbol,
        file: String,
        line: Int,
        column: Int,
        roles: IndexedSymbolRoles,
    ) {
        self.symbol = symbol
        self.file = file
        self.line = line
        self.column = column
        self.roles = roles
    }

    // MARK: Public

    /// The symbol.
    public let symbol: IndexedSymbol

    /// File path where the occurrence is.
    public let file: String

    /// Line number.
    public let line: Int

    /// Column number.
    public let column: Int

    /// The roles of this occurrence (definition, reference, call, etc.).
    public let roles: IndexedSymbolRoles
}

// MARK: - IndexedSymbolRoles

/// Roles a symbol can have in an occurrence.
public struct IndexedSymbolRoles: OptionSet, Sendable {
    // MARK: Lifecycle

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // MARK: Public

    public static let declaration = Self(rawValue: 1 << 0)
    public static let definition = Self(rawValue: 1 << 1)
    public static let reference = Self(rawValue: 1 << 2)
    public static let read = Self(rawValue: 1 << 3)
    public static let write = Self(rawValue: 1 << 4)
    public static let call = Self(rawValue: 1 << 5)
    public static let dynamic = Self(rawValue: 1 << 6)
    public static let implicit = Self(rawValue: 1 << 7)

    public let rawValue: UInt64

    /// Whether the occurrence represents a declaration site.
    public var isDefinitionLike: Bool {
        contains(.definition) || contains(.declaration)
    }

    /// Whether the occurrence represents an actual use-site.
    public var indicatesUsage: Bool {
        contains(.reference) || contains(.call) || contains(.read) || contains(.write)
    }
}

// MARK: - IndexStoreReader

/// Reads symbol information from a Swift index store.
///
/// ## Thread Safety Design
///
/// This class uses `@unchecked Sendable` because the underlying `IndexStoreDB`
/// from Apple's swift-package-manager repository is not marked as `Sendable`,
/// even though it is documented to be thread-safe for read operations.
///
/// ## SAFETY
///
/// The `@unchecked Sendable` conformance is safe because:
///
/// 1. **IndexStoreDB Thread Safety**: According to Apple's documentation,
///    `IndexStoreDB` is internally thread-safe for concurrent read operations.
///    All methods on this class are read-only operations.
///
/// 2. **Immutable After Init**: The `db` property is set once in `init` and
///    never mutated afterward. All operations are read-only queries.
///
/// 3. **No Mutable State**: This class has no mutable stored properties after
///    initialization. The `indexStorePath` is a `let` constant.
///
/// - SeeAlso: `SymbolFinder` which wraps this type with additional locking.
/// - SeeAlso: `IndexBasedDependencyGraph` which documents the full rationale.
public final class IndexStoreReader: @unchecked Sendable {
    // MARK: Lifecycle

    /// Initialize with the path to the index store directory.
    ///
    /// Typed throws: every failure surface is collapsed into
    /// ``IndexStoreError`` so callers don't have to inspect Foundation /
    /// IndexStoreDB internals.
    ///
    /// - Parameters:
    ///   - indexStorePath: Path to the index store (e.g.,
    ///     `.build/debug/index/store`).
    ///   - libIndexStorePath: Optional path to `libIndexStore.dylib`.
    ///   - allowsDirectoryCreation: When `true`, the sibling
    ///     `IndexDatabase/` directory is created if missing. CLI
    ///     auto-discovery sets this to `true` because it has authority over
    ///     the project workspace; the MCP server sets it to `false` so a
    ///     hostile prompt cannot drive a directory-creation side effect at
    ///     an attacker-chosen filesystem location. When `false` and the
    ///     directory does not exist, the initialiser throws
    ///     ``IndexStoreError/databaseDirectoryMissing(_:)`` instead of
    ///     materialising it.
    public init(
        indexStorePath: String,
        libIndexStorePath: String? = nil,
        allowsDirectoryCreation: Bool = false,
    ) throws(IndexStoreError) {
        self.indexStorePath = indexStorePath

        let libPath: String
        if let provided = libIndexStorePath {
            libPath = provided
        } else if let resolved = Self.findLibIndexStore() {
            libPath = resolved
        } else {
            throw IndexStoreError.dylibNotFound
        }

        let storePath = URL(fileURLWithPath: indexStorePath)
        let databasePath = storePath.deletingLastPathComponent().appendingPathComponent("IndexDatabase")

        if allowsDirectoryCreation {
            do {
                try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)
            } catch {
                throw IndexStoreError.failedToOpenDatabase(underlying: error)
            }
        } else {
            // Sandboxed callers (notably the MCP server) supply paths that
            // they have already validated against a codebase root, but the
            // reader itself must not perform filesystem-write side effects:
            // refuse to materialise `IndexDatabase/` and require the caller
            // to opt into it.
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: databasePath.path,
                isDirectory: &isDirectory
            )
            if !exists || !isDirectory.boolValue {
                throw IndexStoreError.databaseDirectoryMissing(databasePath.path)
            }
        }

        do {
            db = try IndexStoreDB(
                storePath: storePath.path,
                databasePath: databasePath.path,
                library: IndexStoreLibrary(dylibPath: libPath),
                waitUntilDoneInitializing: true,
            )
        } catch {
            throw IndexStoreError.failedToOpenDatabase(underlying: error)
        }
    }

    // MARK: Public

    /// The path to the index store.
    public let indexStorePath: String

    /// Find libIndexStore.dylib in the system.
    ///
    /// Each candidate path is verified to be a regular file owned by
    /// `root` (uid 0) before it's returned. Without that check, a low-
    /// privilege user with write access under
    /// `/Applications/Xcode.app/...` or `/Library/Developer/...` (rare,
    /// but plausible in shared dev / CI environments) could plant a
    /// hostile dylib that this process would later `dlopen`. The
    /// owner check is the smallest defence-in-depth gate against that
    /// shape.
    public static func findLibIndexStore() -> String? {
        // Try common locations
        let possiblePaths = [
            // Xcode toolchain
            // swiftlint:disable:next line_length
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
            // Swift toolchain
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/lib/libIndexStore.dylib",
            // Command line tools
            "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib",
        ]

        for path in possiblePaths where Self.isTrustedDylib(at: path) {
            return path
        }

        // Fallback to xcrun. Routes through `ProcessExecutor` so the
        // child does not inherit `DEVELOPER_DIR` from the parent — if
        // the parent's `DEVELOPER_DIR` points at a hostile toolchain,
        // that's a code-execution vector into the host process via
        // `libIndexStore.dylib`.
        if let result = try? ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--find", "swift"]
        ), result.succeeded {
            let swiftPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !swiftPath.isEmpty {
                let toolchainPath = URL(fileURLWithPath: swiftPath)
                    .deletingLastPathComponent()  // bin
                    .deletingLastPathComponent()  // usr
                    .appendingPathComponent("lib")
                    .appendingPathComponent("libIndexStore.dylib")
                let resolved = toolchainPath.path
                if Self.isTrustedDylib(at: resolved) {
                    return resolved
                }
            }
        }

        // No trusted dylib located. Returning `nil` (vs. the previous empty
        // string) surfaces as `IndexStoreError.dylibNotFound` at the call
        // site rather than crashing inside the C++ `IndexStoreLibrary` init.
        return nil
    }

    /// Verify a candidate `libIndexStore.dylib` path is a regular file
    /// owned by `root` (uid 0). Returning `true` means it's safe to
    /// hand to `IndexStoreLibrary.init`; `false` means skip this
    /// candidate.
    private static func isTrustedDylib(at path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        // Reject symlinks at this layer — `IndexStoreLibrary` will
        // dlopen whatever resolves, and a symlink in a writable
        // toolchain directory is a redirect we have no business
        // following without an explicit check.
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        // Owner must be root (uid 0). Any other owner means a non-
        // privileged user could have replaced the dylib.
        return info.st_uid == 0
    }

    /// Find all occurrences of a symbol with the given name.
    public func findOccurrences(ofSymbolNamed name: String) -> [IndexedOccurrence] {
        var occurrences: [IndexedOccurrence] = []

        db.forEachCanonicalSymbolOccurrence(
            containing: name,
            anchorStart: true,
            anchorEnd: true,
            subsequence: false,
            ignoreCase: false,
        ) { occurrence in
            let indexedSymbol = convertSymbol(occurrence.symbol)
            let roles = convertRoles(occurrence.roles)

            occurrences.append(
                IndexedOccurrence(
                    symbol: indexedSymbol,
                    file: occurrence.location.path,
                    line: occurrence.location.line,
                    column: occurrence.location.utf8Column,
                    roles: roles,
                ))

            return true  // Continue iteration
        }

        return occurrences
    }

    /// Find all occurrences of a symbol by USR.
    public func findOccurrences(ofUSR usr: String) -> [IndexedOccurrence] {
        var occurrences: [IndexedOccurrence] = []

        db.forEachSymbolOccurrence(byUSR: usr, roles: .all) { occurrence in
            let indexedSymbol = convertSymbol(occurrence.symbol)
            let roles = convertRoles(occurrence.roles)

            occurrences.append(
                IndexedOccurrence(
                    symbol: indexedSymbol,
                    file: occurrence.location.path,
                    line: occurrence.location.line,
                    column: occurrence.location.utf8Column,
                    roles: roles,
                ))

            return true  // Continue iteration
        }

        return occurrences
    }

    /// Get all symbols defined in the index.
    public func allDefinedSymbols() -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        var seenUSRs = Set<String>()

        // We need to iterate through all symbols
        // IndexStoreDB doesn't have a direct "all symbols" API,
        // so we search with an empty pattern
        db.forEachCanonicalSymbolOccurrence(
            containing: "",
            anchorStart: false,
            anchorEnd: false,
            subsequence: false,
            ignoreCase: false,
        ) { occurrence in
            let symbol = occurrence.symbol
            if !seenUSRs.contains(symbol.usr) {
                seenUSRs.insert(symbol.usr)
                symbols.append(convertSymbol(symbol))
            }
            return true
        }

        return symbols
    }

    /// Check if a symbol (by USR) has any references (not just definitions).
    public func hasReferences(usr: String) -> Bool {
        var hasRef = false

        db.forEachSymbolOccurrence(byUSR: usr, roles: .reference) { _ in
            hasRef = true
            return false  // Stop iteration
        }

        return hasRef
    }

    /// All index occurrences across `files`, grouped by USR.
    ///
    /// This is the avoid-the-N+1 building block for callers that need every
    /// occurrence of every definition. The previous pattern in
    /// `IndexStoreAnalyzer.analyzeUsage` called `findOccurrences(ofUSR:)` per
    /// definition, paying one index round-trip for every symbol. Iterating
    /// each file once and grouping locally is O(total_occurrences) instead
    /// of O(definitions * total_occurrences).
    ///
    /// - Parameter files: Files to include. Pass the empty set to sweep
    ///   every file the index knows about (caller pays for the bigger walk).
    /// - Returns: Dictionary mapping each USR to its full occurrence list.
    public func allOccurrencesByUSR(in files: Set<String>) -> [String: [IndexedOccurrence]] {
        var byUSR: [String: [IndexedOccurrence]] = [:]
        for filePath in files {
            let occurrences = db.symbolOccurrences(inFilePath: filePath)
            for occurrence in occurrences {
                let indexedSymbol = convertSymbol(occurrence.symbol)
                let roles = convertRoles(occurrence.roles)
                byUSR[occurrence.symbol.usr, default: []].append(
                    IndexedOccurrence(
                        symbol: indexedSymbol,
                        file: occurrence.location.path,
                        line: occurrence.location.line,
                        column: occurrence.location.utf8Column,
                        roles: roles,
                    )
                )
            }
        }
        return byUSR
    }

    /// Get all definitions from canonical symbol occurrences.
    public func allDefinitions() -> [IndexedOccurrence] {
        var occurrences: [IndexedOccurrence] = []

        // Search for all symbols and filter to definitions
        db.forEachCanonicalSymbolOccurrence(
            containing: "",
            anchorStart: false,
            anchorEnd: false,
            subsequence: false,
            ignoreCase: false,
        ) { occurrence in
            if occurrence.roles.contains(.definition) || occurrence.roles.contains(.declaration) {
                let indexedSymbol = convertSymbol(occurrence.symbol)
                let roles = convertRoles(occurrence.roles)

                occurrences.append(
                    IndexedOccurrence(
                        symbol: indexedSymbol,
                        file: occurrence.location.path,
                        line: occurrence.location.line,
                        column: occurrence.location.utf8Column,
                        roles: roles,
                    ))
            }
            return true
        }

        return occurrences
    }

    /// Poll for changes to the index.
    public func pollForChanges() {
        db.pollForUnitChangesAndWait()
    }

    // MARK: Private

    /// The underlying IndexStoreDB database.
    private let db: IndexStoreDB

    // MARK: - Private Helpers

    private func convertSymbol(_ symbol: Symbol) -> IndexedSymbol {
        IndexedSymbol(
            usr: symbol.usr,
            name: symbol.name,
            kind: IndexedSymbolKind(from: symbol.kind),
            isSystem: false,  // IndexStoreDB doesn't expose this directly
        )
    }

    private func convertRoles(_ roles: SymbolRole) -> IndexedSymbolRoles {
        var result = IndexedSymbolRoles()

        if roles.contains(.declaration) { result.insert(.declaration) }
        if roles.contains(.definition) { result.insert(.definition) }
        if roles.contains(.reference) { result.insert(.reference) }
        if roles.contains(.read) { result.insert(.read) }
        if roles.contains(.write) { result.insert(.write) }
        if roles.contains(.call) { result.insert(.call) }
        if roles.contains(.dynamic) { result.insert(.dynamic) }
        if roles.contains(.implicit) { result.insert(.implicit) }

        return result
    }
}

// MARK: - IndexStorePathFinder

/// Utility for finding index store paths in a project.
public struct IndexStorePathFinder: Sendable {
    /// Find the index store path for a Swift package.
    public static func findIndexStorePath(in projectRoot: String) -> String? {
        let buildDir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".build")

        // Check debug first
        let debugIndexStore =
            buildDir
            .appendingPathComponent("debug")
            .appendingPathComponent("index")
            .appendingPathComponent("store")

        if FileManager.default.fileExists(atPath: debugIndexStore.path) {
            return debugIndexStore.path
        }

        // Check release
        let releaseIndexStore =
            buildDir
            .appendingPathComponent("release")
            .appendingPathComponent("index")
            .appendingPathComponent("store")

        if FileManager.default.fileExists(atPath: releaseIndexStore.path) {
            return releaseIndexStore.path
        }

        // Check for Xcode DerivedData
        let derivedData = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Developer")
            .appendingPathComponent("Xcode")
            .appendingPathComponent("DerivedData")

        // Try to find matching project
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: derivedData.path) {
            let projectName = URL(fileURLWithPath: projectRoot).lastPathComponent
            // Xcode normalizes project names in DerivedData: spaces become underscores
            let normalizedProjectName = normalizeProjectName(projectName)
            for dir in contents
            where dirMatchesProject(dir, projectName: projectName, normalizedName: normalizedProjectName) {
                let dataStore =
                    derivedData
                    .appendingPathComponent(dir)
                    .appendingPathComponent("Index.noindex")
                    .appendingPathComponent("DataStore")

                // Modern Xcode stores index data in versioned subdirectories (v5, v6, etc.)
                // Look for the highest versioned subdirectory containing records/units
                if let versionedPath = findVersionedIndexStore(in: dataStore) {
                    return versionedPath
                }

                // Fallback to DataStore if no versioned subdirectory
                if FileManager.default.fileExists(atPath: dataStore.path) {
                    return dataStore.path
                }
            }
        }

        return nil
    }

    /// Find the versioned index store subdirectory (e.g., v5, v6)
    private static func findVersionedIndexStore(in dataStore: URL) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dataStore.path) else {
            return nil
        }

        // Find versioned directories (v5, v6, etc.) that contain records and units
        let versionedDirs =
            contents
            .filter { $0.hasPrefix("v") && $0.dropFirst().allSatisfy(\.isNumber) }
            .sorted { lhs, rhs in
                // Sort by version number descending to get the highest version first
                let lhsNum = Int(lhs.dropFirst()) ?? 0
                let rhsNum = Int(rhs.dropFirst()) ?? 0
                return lhsNum > rhsNum
            }

        for versionedDir in versionedDirs {
            let versionedPath = dataStore.appendingPathComponent(versionedDir)
            let recordsPath = versionedPath.appendingPathComponent("records")
            let unitsPath = versionedPath.appendingPathComponent("units")

            // Verify this versioned directory contains the expected structure
            if FileManager.default.fileExists(atPath: recordsPath.path)
                || FileManager.default.fileExists(atPath: unitsPath.path)
            {
                return versionedPath.path
            }
        }

        return nil
    }

    /// Normalize project name to match Xcode's DerivedData naming convention.
    /// Xcode replaces spaces and other special characters with underscores.
    private static func normalizeProjectName(_ name: String) -> String {
        // Xcode replaces these characters with underscores in DerivedData folder names
        let charactersToReplace = CharacterSet(charactersIn: " -.")
        var normalized = name
        for scalar in name.unicodeScalars where charactersToReplace.contains(scalar) {
            normalized = normalized.replacingOccurrences(of: String(scalar), with: "_")
        }
        return normalized
    }

    /// URL-encode project name as a fallback matching strategy.
    /// Some tools may use percent-encoding for special characters.
    private static func urlEncodeProjectName(_ name: String) -> String? {
        // Only encode if there are characters that need encoding
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    /// Check if a DerivedData directory name matches a project name.
    /// Handles exact matches, normalized matches (spaces -> underscores), and URL-encoded matches.
    private static func dirMatchesProject(_ dir: String, projectName: String, normalizedName: String) -> Bool {
        // DerivedData folders are named: ProjectName-hash
        // Extract the project name portion (before the hash)
        let components = dir.split(separator: "-", maxSplits: 1)
        guard let dirProjectName = components.first else {
            return false
        }

        let dirNameStr = String(dirProjectName)

        // Check exact match first
        if dirNameStr == projectName {
            return true
        }

        // Check normalized match (handles spaces -> underscores, etc.)
        if dirNameStr == normalizedName {
            return true
        }

        // Check URL-encoded match (handles spaces -> %20, etc.)
        if let urlEncoded = urlEncodeProjectName(projectName), dirNameStr == urlEncoded {
            return true
        }

        // Check if directory name is URL-encoded and matches when decoded
        if let decoded = dirNameStr.removingPercentEncoding, decoded == projectName {
            return true
        }

        // Also check if the directory contains the project name (legacy behavior)
        // This handles edge cases like additional suffixes
        return dir.contains(projectName) || dir.contains(normalizedName)
    }
}
