//
//  IndexStoreReader.swift
//  SwiftStaticAnalysis
//
//  Wrapper around IndexStoreDB for reading Swift index data.
//

import Foundation
import IndexStoreDB
import SwiftStaticAnalysisCore

// MARK: - Index Store Error

/// Errors that can occur when reading the index store.
public enum IndexStoreError: Error, Sendable {
    case indexStoreNotFound(path: String)
    case failedToOpenDatabase(underlying: Error)
    case invalidConfiguration
    case noIndexStoreForProject
}

// MARK: - Symbol Info

/// Information about a symbol from the index store.
public struct IndexedSymbol: Sendable {
    /// The symbol's USR (Unique Symbol Reference).
    public let usr: String

    /// The symbol name.
    public let name: String

    /// The kind of symbol.
    public let kind: IndexedSymbolKind

    /// Whether this is a system symbol.
    public let isSystem: Bool

    public init(usr: String, name: String, kind: IndexedSymbolKind, isSystem: Bool) {
        self.usr = usr
        self.name = name
        self.kind = kind
        self.isSystem = isSystem
    }
}

// MARK: - Indexed Symbol Kind

/// Kinds of symbols in the index store.
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
}

// MARK: - Symbol Occurrence Info

/// Information about where a symbol occurs in the codebase.
public struct IndexedOccurrence: Sendable {
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

    public init(
        symbol: IndexedSymbol,
        file: String,
        line: Int,
        column: Int,
        roles: IndexedSymbolRoles
    ) {
        self.symbol = symbol
        self.file = file
        self.line = line
        self.column = column
        self.roles = roles
    }
}

// MARK: - Symbol Roles

/// Roles a symbol can have in an occurrence.
public struct IndexedSymbolRoles: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let declaration = IndexedSymbolRoles(rawValue: 1 << 0)
    public static let definition = IndexedSymbolRoles(rawValue: 1 << 1)
    public static let reference = IndexedSymbolRoles(rawValue: 1 << 2)
    public static let read = IndexedSymbolRoles(rawValue: 1 << 3)
    public static let write = IndexedSymbolRoles(rawValue: 1 << 4)
    public static let call = IndexedSymbolRoles(rawValue: 1 << 5)
    public static let `dynamic` = IndexedSymbolRoles(rawValue: 1 << 6)
    public static let implicit = IndexedSymbolRoles(rawValue: 1 << 7)
}

// MARK: - Index Store Reader

/// Reads symbol information from a Swift index store.
public final class IndexStoreReader: @unchecked Sendable {
    /// The underlying IndexStoreDB database.
    private let db: IndexStoreDB

    /// The path to the index store.
    public let indexStorePath: String

    /// Initialize with the path to the index store directory.
    ///
    /// - Parameter indexStorePath: Path to the index store (e.g., .build/debug/index/store)
    /// - Parameter libIndexStorePath: Optional path to libIndexStore.dylib
    public init(indexStorePath: String, libIndexStorePath: String? = nil) throws {
        self.indexStorePath = indexStorePath

        // Find libIndexStore.dylib
        let libPath: String
        if let provided = libIndexStorePath {
            libPath = provided
        } else {
            // Try to find it in the Xcode toolchain
            libPath = Self.findLibIndexStore()
        }

        // Create the IndexStoreDB
        do {
            let storePath = URL(fileURLWithPath: indexStorePath)
            let databasePath = storePath.deletingLastPathComponent().appendingPathComponent("IndexDatabase")

            // Create database directory if needed
            try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)

            self.db = try IndexStoreDB(
                storePath: storePath.path,
                databasePath: databasePath.path,
                library: IndexStoreLibrary(dylibPath: libPath),
                waitUntilDoneInitializing: true
            )
        } catch {
            throw IndexStoreError.failedToOpenDatabase(underlying: error)
        }
    }

    /// Find all occurrences of a symbol with the given name.
    public func findOccurrences(ofSymbolNamed name: String) -> [IndexedOccurrence] {
        var occurrences: [IndexedOccurrence] = []

        db.forEachCanonicalSymbolOccurrence(
            containing: name,
            anchorStart: true,
            anchorEnd: true,
            subsequence: false,
            ignoreCase: false
        ) { occurrence in
            let indexedSymbol = convertSymbol(occurrence.symbol)
            let roles = convertRoles(occurrence.roles)

            occurrences.append(IndexedOccurrence(
                symbol: indexedSymbol,
                file: occurrence.location.path,
                line: occurrence.location.line,
                column: occurrence.location.utf8Column,
                roles: roles
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
                roles: roles
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
            ignoreCase: false
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
            ignoreCase: false
        ) { occurrence in
            if occurrence.roles.contains(.definition) || occurrence.roles.contains(.declaration) {
                let indexedSymbol = convertSymbol(occurrence.symbol)
                let roles = convertRoles(occurrence.roles)

                occurrences.append(IndexedOccurrence(
                    symbol: indexedSymbol,
                    file: occurrence.location.path,
                    line: occurrence.location.line,
                    column: occurrence.location.utf8Column,
                    roles: roles
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

    // MARK: - Private Helpers

    private func convertSymbol(_ symbol: Symbol) -> IndexedSymbol {
        IndexedSymbol(
            usr: symbol.usr,
            name: symbol.name,
            kind: convertSymbolKind(symbol.kind),
            isSystem: false // IndexStoreDB doesn't expose this directly
        )
    }

    private func convertSymbolKind(_ kind: IndexSymbolKind) -> IndexedSymbolKind {
        switch kind {
        case .class: return .class
        case .struct: return .struct
        case .enum: return .enum
        case .protocol: return .protocol
        case .extension: return .extension
        case .function, .classMethod, .instanceMethod, .staticMethod:
            return .function
        case .instanceProperty, .staticProperty, .classProperty:
            return .property
        case .variable:
            return .variable
        case .parameter:
            return .parameter
        case .typealias:
            return .typealias
        case .module:
            return .module
        default:
            return .unknown
        }
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

    /// Find libIndexStore.dylib in the system.
    private static func findLibIndexStore() -> String {
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
}

// MARK: - Index Store Path Finder

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
