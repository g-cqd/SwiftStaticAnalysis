//
//  IndexStoreReader.swift
//  SwiftStaticAnalysis
//
//  Wrapper around IndexStoreDB for reading Swift index data.
//

import Foundation
import IndexStoreDB
import SwiftStaticAnalysisCore

// MARK: - IndexStoreError

/// Errors that can occur when reading the index store.
/// Exhaustive error cases for comprehensive error handling. // swa:ignore-unused-cases
public enum IndexStoreError: Error, Sendable {
    case indexStoreNotFound(path: String)
    case failedToOpenDatabase(underlying: Error)
    case invalidConfiguration
    case noIndexStoreForProject
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
public enum IndexedSymbolKind: String, Sendable, DeclarationKindConvertible {
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
             .method: .function
        case .property,
             .variable: .variable
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

    public static let declaration = IndexedSymbolRoles(rawValue: 1 << 0)
    public static let definition = IndexedSymbolRoles(rawValue: 1 << 1)
    public static let reference = IndexedSymbolRoles(rawValue: 1 << 2)
    public static let read = IndexedSymbolRoles(rawValue: 1 << 3)
    public static let write = IndexedSymbolRoles(rawValue: 1 << 4)
    public static let call = IndexedSymbolRoles(rawValue: 1 << 5)
    public static let dynamic = IndexedSymbolRoles(rawValue: 1 << 6)
    public static let implicit = IndexedSymbolRoles(rawValue: 1 << 7)

    public let rawValue: UInt64
}

// MARK: - IndexStoreReader

/// Reads symbol information from a Swift index store.
public final class IndexStoreReader: @unchecked Sendable {
    // MARK: Lifecycle

    /// Initialize with the path to the index store directory.
    ///
    /// - Parameter indexStorePath: Path to the index store (e.g., .build/debug/index/store)
    /// - Parameter libIndexStorePath: Optional path to libIndexStore.dylib
    public init(indexStorePath: String, libIndexStorePath: String? = nil) throws {
        self.indexStorePath = indexStorePath

        // Find libIndexStore.dylib
        let libPath: String = if let provided = libIndexStorePath {
            provided
        } else {
            // Try to find it in the Xcode toolchain
            Self.findLibIndexStore()
        }

        // Create the IndexStoreDB
        do {
            let storePath = URL(fileURLWithPath: indexStorePath)
            let databasePath = storePath.deletingLastPathComponent().appendingPathComponent("IndexDatabase")

            // Create database directory if needed
            try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)

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
    public static func findLibIndexStore() -> String {
        // Try common locations
        let possiblePaths = [
            // Xcode toolchain
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
            // Swift toolchain
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/lib/libIndexStore.dylib",
            // Command line tools
            "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib",
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback to xcrun
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swift"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let swiftPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let toolchainPath = URL(fileURLWithPath: swiftPath)
                    .deletingLastPathComponent() // bin
                    .deletingLastPathComponent() // usr
                    .appendingPathComponent("lib")
                    .appendingPathComponent("libIndexStore.dylib")
                return toolchainPath.path
            }
        } catch {
            // Fall through to default
        }

        // Default fallback
        return "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
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

            occurrences.append(IndexedOccurrence(
                symbol: indexedSymbol,
                file: occurrence.location.path,
                line: occurrence.location.line,
                column: occurrence.location.utf8Column,
                roles: roles,
            ))

            return true // Continue iteration
        }

        return occurrences
    }

    /// Find all occurrences of a symbol by USR.
    public func findOccurrences(ofUSR usr: String) -> [IndexedOccurrence] {
        var occurrences: [IndexedOccurrence] = []

        db.forEachSymbolOccurrence(byUSR: usr, roles: .all) { occurrence in
            let indexedSymbol = convertSymbol(occurrence.symbol)
            let roles = convertRoles(occurrence.roles)

            occurrences.append(IndexedOccurrence(
                symbol: indexedSymbol,
                file: occurrence.location.path,
                line: occurrence.location.line,
                column: occurrence.location.utf8Column,
                roles: roles,
            ))

            return true // Continue iteration
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
            return false // Stop iteration
        }

        return hasRef
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

                occurrences.append(IndexedOccurrence(
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
            isSystem: false, // IndexStoreDB doesn't expose this directly
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
        let debugIndexStore = buildDir
            .appendingPathComponent("debug")
            .appendingPathComponent("index")
            .appendingPathComponent("store")

        if FileManager.default.fileExists(atPath: debugIndexStore.path) {
            return debugIndexStore.path
        }

        // Check release
        let releaseIndexStore = buildDir
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
            for dir in contents where dir.contains(projectName) {
                let indexStore = derivedData
                    .appendingPathComponent(dir)
                    .appendingPathComponent("Index.noindex")
                    .appendingPathComponent("DataStore")

                if FileManager.default.fileExists(atPath: indexStore.path) {
                    return indexStore.path
                }
            }
        }

        return nil
    }
}
