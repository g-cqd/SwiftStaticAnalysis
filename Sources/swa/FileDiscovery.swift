//  FileDiscovery.swift
//  swa
//  MIT License
//
//  CLI-side Swift file enumeration. Extracted from SWA.swift in Phase 6
//  of the audit-driven cleanup. The canonical-cross-module move into
//  SwiftStaticAnalysisCore is tracked separately — for now this is the
//  CLI's authoritative copy and the MCP / bench duplicates remain.

import Foundation
import SwiftStaticAnalysisCore
import UnusedCodeDetector

/// Default directories to always exclude from analysis. These contain
/// build artifacts, dependencies, and auto-generated code.
private let defaultExcludedDirectories: Set<String> = [
    ".build",  // Swift Package Manager build artifacts
    "Build",  // Xcode build directory
    "DerivedData",  // Xcode derived data
    ".swiftpm",  // SwiftPM metadata
    "Pods",  // CocoaPods dependencies
    "Carthage",  // Carthage dependencies
    ".git",  // Git metadata
]

// MARK: - File Discovery

func findSwiftFiles(in paths: [String], excludePaths: [String]? = nil) throws -> [String] {
    let fileManager = FileManager.default
    var swiftFiles: [String] = []

    for path in paths {
        // Canonicalize path to prevent path traversal attacks. Use the
        // CWD as the resolution base so relative inputs (`.`, `Sources`)
        // resolve consistently with the rest of the toolchain.
        let canonicalPath = PathUtilities.canonicalize(
            path,
            relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath)
        )
        let url = URL(fileURLWithPath: canonicalPath)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalPath, isDirectory: &isDirectory) else {
            throw AnalysisError.fileNotFound(canonicalPath)
        }

        if !isDirectory.boolValue {
            // Single file
            guard canonicalPath.hasSuffix(".swift") else {
                throw AnalysisError.invalidPath("Not a Swift file: \(canonicalPath)")
            }
            // Apply exclusion patterns to single files too
            if let excludePaths, !excludePaths.isEmpty {
                let shouldExclude = excludePaths.contains { pattern in
                    UnusedCodeFilter.matchesGlobPattern(canonicalPath, pattern: pattern)
                }
                if shouldExclude {
                    continue
                }
            }
            swiftFiles.append(canonicalPath)
            continue
        }

        // Directory - find all Swift files.
        //
        // The enumerator follows symlinks by default. We re-resolve each
        // discovered file's canonical path and verify it stays underneath
        // the original directory root, matching the hygiene that
        // `CodebaseContext.findSwiftFiles` applies on the MCP side. A
        // symlink pointing at `/tmp/.build/...` would otherwise sneak
        // generated artifacts into the analysis.
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
        ) {
            let rootPrefix = canonicalPath.hasSuffix("/") ? canonicalPath : canonicalPath + "/"
            for case let fileURL as URL in enumerator {
                // Skip default excluded directories (even if not hidden)
                let pathComponents = fileURL.pathComponents
                if pathComponents.contains(where: { defaultExcludedDirectories.contains($0) }) {
                    continue
                }

                // Only process Swift files
                guard fileURL.pathExtension == "swift" else {
                    continue
                }

                let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == canonicalPath || resolved.hasPrefix(rootPrefix) else {
                    continue
                }

                let filePath = resolved

                // Apply exclusion patterns
                if let excludePaths, !excludePaths.isEmpty {
                    let shouldExclude = excludePaths.contains { pattern in
                        UnusedCodeFilter.matchesGlobPattern(filePath, pattern: pattern)
                    }
                    if shouldExclude {
                        continue
                    }
                }

                swiftFiles.append(filePath)
            }
        }
    }

    return swiftFiles.sorted()
}
