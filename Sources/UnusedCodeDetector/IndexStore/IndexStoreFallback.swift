//
//  IndexStoreFallback.swift
//  SwiftStaticAnalysis
//
//  Graceful degradation and fallback mechanisms for IndexStore-based analysis.
//
//  This module provides:
//  - Index store availability detection
//  - Freshness checking (comparing index with source files)
//  - Auto-build option to ensure fresh index
//  - Fallback to syntax-based analysis when index unavailable
//  - Hybrid mode combining index and syntax analysis
//

import Foundation
@preconcurrency import IndexStoreDB
import SwiftStaticAnalysisCore

// MARK: - IndexStoreStatus

/// Status of the index store for analysis.
public enum IndexStoreStatus: Sendable {
    /// Index store exists and is up-to-date.
    case available(path: String)

    /// Index store exists but is stale (source files modified after index).
    case stale(path: String, staleFiles: [String])

    /// Index store does not exist.
    case notFound

    /// Index store exists but failed to open.
    case failed(error: String)

    // MARK: Public

    /// Whether the index is usable (available or stale with warnings).
    public var isUsable: Bool {
        switch self {
        case .available,
             .stale:
            true
        case .failed,
             .notFound:
            false
        }
    }

    /// The path to the index store, if available.
    public var path: String? {
        switch self {
        case let .available(path),
             let .stale(path, _):
            path
        case .failed,
             .notFound:
            nil
        }
    }
}

// MARK: - AnalysisModeResult

/// Result of determining which analysis mode to use.
public enum AnalysisModeResult {
    /// Use index store based analysis.
    case indexStore(db: IndexStoreDB, status: IndexStoreStatus)

    /// Fall back to reachability-based analysis.
    case reachability(reason: FallbackReason)

    /// Use hybrid mode (index for cross-module, syntax for local).
    case hybrid(db: IndexStoreDB, status: IndexStoreStatus)
}

// MARK: - FallbackReason

/// Reason for falling back to syntax-based analysis.
public enum FallbackReason: Sendable, CustomStringConvertible {
    /// No index store found.
    case noIndexStore

    /// Index store failed to open.
    case indexStoreFailed(error: String)

    /// Auto-build was attempted but failed.
    case buildFailed(error: String)

    /// User requested syntax-only mode.
    case userRequested

    // MARK: Public

    public var description: String {
        switch self {
        case .noIndexStore:
            "No index store found. Run 'swift build' to generate one."

        case let .indexStoreFailed(error):
            "Failed to open index store: \(error)"

        case let .buildFailed(error):
            "Build failed: \(error)"

        case .userRequested:
            "Syntax-only mode requested by user."
        }
    }
}

// MARK: - BuildResult

/// Result of attempting to build the project.
public struct BuildResult: Sendable {
    // MARK: Lifecycle

    public init(success: Bool, output: String, duration: TimeInterval, indexStorePath: String?) {
        self.success = success
        self.output = output
        self.duration = duration
        self.indexStorePath = indexStorePath
    }

    // MARK: Public

    /// Whether the build succeeded.
    public let success: Bool

    /// Build output (stdout + stderr).
    public let output: String

    /// Duration of the build in seconds.
    public let duration: TimeInterval

    /// Path to generated index store (if successful).
    public let indexStorePath: String?
}

// MARK: - IndexStoreFallbackManager

/// Manages index store availability and fallback strategies.
public final class IndexStoreFallbackManager: @unchecked Sendable {
    // MARK: Lifecycle

    public init(configuration: FallbackConfiguration = .default, libIndexStorePath: String? = nil) {
        self.configuration = configuration
        self.libIndexStorePath = libIndexStorePath
    }

    // MARK: Public

    /// Configuration for fallback behavior.
    public let configuration: FallbackConfiguration

    // MARK: - Status Checking

    /// Check the status of the index store for a project.
    ///
    /// - Parameters:
    ///   - projectRoot: Path to the project root.
    ///   - sourceFiles: Source files to check for freshness.
    /// - Returns: The status of the index store.
    public func checkIndexStoreStatus(
        projectRoot: String,
        sourceFiles: [String],
    ) -> IndexStoreStatus {
        // Try to find the index store
        guard let indexStorePath = IndexStorePathFinder.findIndexStorePath(in: projectRoot) else {
            return .notFound
        }

        // Try to open it
        do {
            let reader = try IndexStoreReader(
                indexStorePath: indexStorePath,
                libIndexStorePath: libIndexStorePath,
            )

            // Check freshness if enabled
            if configuration.checkFreshness {
                let staleFiles = findStaleFiles(
                    sourceFiles: sourceFiles,
                    indexStorePath: indexStorePath,
                    reader: reader,
                )

                if !staleFiles.isEmpty {
                    return .stale(path: indexStorePath, staleFiles: staleFiles)
                }
            }

            return .available(path: indexStorePath)
        } catch {
            return .failed(error: error.localizedDescription)
        }
    }

    // MARK: - Auto Build

    /// Attempt to build the project to generate/update the index store.
    ///
    /// - Parameter projectRoot: Path to the project root.
    /// - Returns: The build result.
    public func autoBuild(projectRoot: String) async -> BuildResult {
        let startTime = Date()

        // Detect project type and build
        let projectURL = URL(fileURLWithPath: projectRoot)
        let packageSwift = projectURL.appendingPathComponent("Package.swift")

        if FileManager.default.fileExists(atPath: packageSwift.path) {
            // Swift Package Manager project
            return await buildSPMProject(at: projectRoot, startTime: startTime)
        }

        // Check for Xcode project
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: projectRoot),
           contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return await buildXcodeProject(at: projectRoot, startTime: startTime)
        }

        return BuildResult(
            success: false,
            output: "Could not determine project type. No Package.swift or .xcodeproj found.",
            duration: Date().timeIntervalSince(startTime),
            indexStorePath: nil,
        )
    }

    // MARK: - Analysis Mode Selection

    /// Determine which analysis mode to use.
    ///
    /// - Parameters:
    ///   - projectRoot: Path to the project root.
    ///   - sourceFiles: Source files to analyze.
    ///   - preferredMode: The preferred mode from configuration.
    /// - Returns: The analysis mode to use.
    public func determineAnalysisMode( // swiftlint:disable:this function_body_length
        projectRoot: String,
        sourceFiles: [String],
        preferredMode: DetectionMode,
    ) async -> AnalysisModeResult {
        // If user explicitly requested simple or reachability mode
        if preferredMode == .simple {
            return .reachability(reason: .userRequested)
        }

        if preferredMode == .reachability {
            return .reachability(reason: .userRequested)
        }

        // Check index store status
        var status = checkIndexStoreStatus(projectRoot: projectRoot, sourceFiles: sourceFiles)

        // If not available and auto-build is enabled, try building
        if !status.isUsable, configuration.autoBuild {
            let buildResult = await autoBuild(projectRoot: projectRoot)

            if buildResult.success, buildResult.indexStorePath != nil {
                // Re-check status
                status = checkIndexStoreStatus(projectRoot: projectRoot, sourceFiles: sourceFiles)
            } else {
                return .reachability(reason: .buildFailed(error: buildResult.output))
            }
        }

        // If still not available, fall back
        if !status.isUsable {
            switch status {
            case .notFound:
                return .reachability(reason: .noIndexStore)

            case let .failed(error):
                return .reachability(reason: .indexStoreFailed(error: error))

            default:
                return .reachability(reason: .noIndexStore)
            }
        }

        // Open the index store
        guard let indexStorePath = status.path else {
            return .reachability(reason: .noIndexStore)
        }

        do {
            let storePath = URL(fileURLWithPath: indexStorePath)
            let databasePath = storePath.deletingLastPathComponent().appendingPathComponent("IndexDatabase")

            try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)

            let libPath = libIndexStorePath ?? IndexStoreReader.findLibIndexStore()

            let db = try IndexStoreDB(
                storePath: storePath.path,
                databasePath: databasePath.path,
                library: IndexStoreLibrary(dylibPath: libPath),
                waitUntilDoneInitializing: true,
            )

            // Warn about stale files if applicable
            if case let .stale(_, staleFiles) = status {
                if configuration.warnOnStale {
                    // Log warning (in a real implementation, use proper logging)
                    print(
                        "Warning: Index store is stale. \(staleFiles.count) file(s) have been modified since last build:",
                    )
                    for file in staleFiles.prefix(5) {
                        print("  - \(file)")
                    }
                    if staleFiles.count > 5 {
                        print("  ... and \(staleFiles.count - 5) more")
                    }
                }
            }

            // Return based on hybrid preference
            if configuration.hybridMode {
                return .hybrid(db: db, status: status)
            } else {
                return .indexStore(db: db, status: status)
            }
        } catch {
            return .reachability(reason: .indexStoreFailed(error: error.localizedDescription))
        }
    }

    // MARK: Private

    /// Path to libIndexStore.dylib.
    private let libIndexStorePath: String?

    /// Find files that are newer than the index.
    private func findStaleFiles(
        sourceFiles: [String],
        indexStorePath: String,
        reader: IndexStoreReader,
    ) -> [String] {
        var staleFiles: [String] = []

        for filePath in sourceFiles {
            // Get source file modification time
            guard let sourceModTime = fileModificationTime(filePath) else {
                continue
            }

            // Get index modification time for this file
            // Use the IndexStoreDB's dateOfLatestUnitFor if available
            // For now, we'll compare against the index store directory mod time
            guard let indexModTime = indexStoreModificationTime(indexStorePath, for: filePath) else {
                // No index for this file yet - it's stale
                staleFiles.append(filePath)
                continue
            }

            if sourceModTime > indexModTime {
                staleFiles.append(filePath)
            }
        }

        return staleFiles
    }

    /// Get the modification time of a file.
    private func fileModificationTime(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// Get the modification time of the index for a file.
    private func indexStoreModificationTime(_ indexStorePath: String, for sourceFile: String) -> Date? {
        // The index store contains unit files that track when files were indexed
        // For a simple check, we look at the store directory modification time
        // A more accurate check would use IndexStoreDB's dateOfLatestUnitFor

        // Try to open the database and check
        do {
            let storePath = URL(fileURLWithPath: indexStorePath)
            let databasePath = storePath.deletingLastPathComponent().appendingPathComponent("IndexDatabase")

            try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)

            let libPath = libIndexStorePath ?? IndexStoreReader.findLibIndexStore()

            let db = try IndexStoreDB(
                storePath: storePath.path,
                databasePath: databasePath.path,
                library: IndexStoreLibrary(dylibPath: libPath),
                waitUntilDoneInitializing: true,
            )

            return db.dateOfLatestUnitFor(filePath: sourceFile)
        } catch {
            // Fallback: check store directory mod time
            return fileModificationTime(indexStorePath)
        }
    }

    /// Build an SPM project.
    private func buildSPMProject(at projectRoot: String, startTime: Date) async -> BuildResult {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", ".build/index/store"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            let success = process.terminationStatus == 0
            let indexPath = success ?
                URL(fileURLWithPath: projectRoot)
                .appendingPathComponent(".build/index/store").path : nil

            return BuildResult(
                success: success,
                output: output,
                duration: Date().timeIntervalSince(startTime),
                indexStorePath: indexPath,
            )
        } catch {
            return BuildResult(
                success: false,
                output: "Failed to run swift build: \(error.localizedDescription)",
                duration: Date().timeIntervalSince(startTime),
                indexStorePath: nil,
            )
        }
    }

    /// Build an Xcode project.
    private func buildXcodeProject( // swiftlint:disable:this function_body_length
        at projectRoot: String,
        startTime: Date,
    ) async -> BuildResult {
        // Find workspace or project
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: projectRoot) else {
            return BuildResult(
                success: false,
                output: "Could not read project directory",
                duration: Date().timeIntervalSince(startTime),
                indexStorePath: nil,
            )
        }

        let workspace = contents.first { $0.hasSuffix(".xcworkspace") }
        let project = contents.first { $0.hasSuffix(".xcodeproj") }

        var arguments = ["build"]

        if let ws = workspace {
            arguments += ["-workspace", ws]
            // Try to find a scheme
            arguments += ["-scheme", URL(fileURLWithPath: ws).deletingPathExtension().lastPathComponent]
        } else if let proj = project {
            arguments += ["-project", proj]
        }

        // Add index store path
        arguments += [
            "INDEX_ENABLE_DATA_STORE=YES",
            "INDEX_DATA_STORE_DIR=$(PROJECT_DIR)/.build/index/store",
        ]

        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            let success = process.terminationStatus == 0

            // Try to find the index store path
            var indexPath: String?
            if success {
                indexPath = IndexStorePathFinder.findIndexStorePath(in: projectRoot)
            }

            return BuildResult(
                success: success,
                output: output,
                duration: Date().timeIntervalSince(startTime),
                indexStorePath: indexPath,
            )
        } catch {
            return BuildResult(
                success: false,
                output: "Failed to run xcodebuild: \(error.localizedDescription)",
                duration: Date().timeIntervalSince(startTime),
                indexStorePath: nil,
            )
        }
    }
}

// MARK: - FallbackConfiguration

/// Configuration for fallback behavior.
public struct FallbackConfiguration: Sendable {
    // MARK: Lifecycle

    public init(
        autoBuild: Bool = false,
        checkFreshness: Bool = true,
        warnOnStale: Bool = true,
        hybridMode: Bool = false,
        maxStaleness: TimeInterval = 3600, // 1 hour
    ) {
        self.autoBuild = autoBuild
        self.checkFreshness = checkFreshness
        self.warnOnStale = warnOnStale
        self.hybridMode = hybridMode
        self.maxStaleness = maxStaleness
    }

    // MARK: Public

    public static let `default` = Self()

    /// Configuration with auto-build enabled.
    public static let withAutoBuild = Self(autoBuild: true)

    /// Configuration for CI/CD where index is expected.
    public static let cicd = Self(
        autoBuild: false,
        checkFreshness: true,
        warnOnStale: false,
        hybridMode: false,
    )

    /// Hybrid mode configuration.
    public static let hybrid = Self(
        autoBuild: false,
        checkFreshness: true,
        warnOnStale: true,
        hybridMode: true,
    )

    /// Whether to automatically build the project if index is missing/stale.
    public var autoBuild: Bool

    /// Whether to check if the index is fresh.
    public var checkFreshness: Bool

    /// Whether to warn when using a stale index.
    public var warnOnStale: Bool

    /// Whether to use hybrid mode (index + syntax).
    public var hybridMode: Bool

    /// Maximum staleness (in seconds) before considering a rebuild.
    public var maxStaleness: TimeInterval
}
