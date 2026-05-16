/// CodebaseContext.swift
/// SwiftStaticAnalysisMCP
/// MIT License

import Foundation
import SwiftStaticAnalysisCore

/// Manages the sandboxed codebase path and ensures all operations are restricted to it.
///
/// `validatePath` canonicalises both the candidate and the codebase root via
/// `URL.resolvingSymlinksInPath()` and compares with a separator-aware prefix,
/// which prevents two classes of attack:
///
/// 1. **Sibling-path bypass**: `/tmp/codebase-secret/...` no longer satisfies
///    a `hasPrefix("/tmp/codebase")` check.
/// 2. **Symlink escape**: a file inside the codebase that symlinks to
///    `/etc/passwd` (or any path outside the canonical root) is rejected.
public struct CodebaseContext: Sendable {
    /// The canonical root path of the codebase being analyzed (symlinks resolved).
    public let rootPath: String

    /// The canonical absolute URL of the root path (symlinks resolved).
    public let rootURL: URL

    /// Initialize with a codebase root path.
    /// - Parameter rootPath: The absolute path to the codebase directory.
    /// - Throws: `CodebaseContextError` if the path is invalid or doesn't exist.
    public init(rootPath: String) throws(CodebaseContextError) {
        let expandedPath = PathUtilities.expandingTildeInPath(rootPath)
        let url = URL(fileURLWithPath: expandedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CodebaseContextError.invalidRootPath(rootPath)
        }

        self.rootPath = url.path
        self.rootURL = url
    }

    /// Validates that a given path is within the sandboxed codebase.
    ///
    /// Both the candidate and the root are canonicalised via
    /// `URL.resolvingSymlinksInPath()` before comparison. A separator-aware
    /// prefix check (`canonical == root || canonical.hasPrefix(root + "/")`)
    /// prevents sibling-path bypass attacks.
    ///
    /// - Parameter path: The path to validate (absolute or relative to root).
    /// - Returns: The canonical absolute path if valid.
    /// - Throws: `CodebaseContextError.pathOutsideSandbox` if the path escapes
    ///           the sandbox after symlink resolution.
    public func validatePath(_ path: String) throws(CodebaseContextError) -> String {
        // Expand a leading ~ to the user's home directory before any other
        // resolution, matching the behaviour of `init(rootPath:)`. Without
        // this step a candidate like "~/.ssh/id_rsa" would be treated as a
        // literal subdirectory of the codebase root — confusing, even if it
        // is not exploitable.
        let expanded = PathUtilities.expandingTildeInPath(path)

        let candidate: URL =
            if expanded.hasPrefix("/") {
                URL(fileURLWithPath: expanded)
            } else {
                rootURL.appendingPathComponent(expanded)
            }

        // Canonicalise via symlink resolution. This collapses .., ., and
        // platform aliases such as /private/var -> /var on macOS.
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL.path

        // Separator-aware prefix check — required because plain hasPrefix
        // would allow /tmp/codebase-secret to match /tmp/codebase.
        guard canonical == rootPath || canonical.hasPrefix(rootPath + "/") else {
            throw CodebaseContextError.pathOutsideSandbox(path, allowedRoot: rootPath)
        }

        return canonical
    }

    /// Validates and returns multiple paths within the sandbox.
    /// - Parameter paths: The paths to validate.
    /// - Returns: Array of canonical absolute paths.
    /// - Throws: `CodebaseContextError.pathOutsideSandbox` if any path escapes the sandbox.
    public func validatePaths(_ paths: [String]) throws(CodebaseContextError) -> [String] {
        var resolved: [String] = []
        resolved.reserveCapacity(paths.count)
        for path in paths {
            resolved.append(try validatePath(path))
        }
        return resolved
    }

    /// Returns all Swift files in the codebase.
    ///
    /// Symbolic links whose canonical target falls outside the codebase root
    /// are silently skipped (not returned). This prevents a hostile codebase
    /// from exposing arbitrary host files via `Sources/normal.swift -> /etc/passwd`.
    ///
    /// - Parameter excludePatterns: Glob patterns to exclude (e.g., "**/Tests/**").
    /// - Returns: Array of canonical absolute paths to Swift files.
    public func findSwiftFiles(excludePatterns: [String] = []) throws(CodebaseContextError) -> [String] {
        // Delegate to the canonical SwiftFileFinder in Core. The
        // strict preset matches the historical hygiene:
        // symlink-canonical-confines-to-root, hidden-file skip,
        // default deny list (.build, Pods, etc.), and glob fast paths.
        // The previous bespoke MCP enumerator handled the same set;
        // routing through Core eliminates the divergent copies.
        let finder = SwiftFileFinder(options: .strict)
        do {
            return try finder.find(in: [rootPath], excludePaths: excludePatterns)
        } catch {
            throw CodebaseContextError.enumerationFailed(rootPath)
        }
    }

    /// Simple glob pattern matching. Delegates to the canonical
    /// `GlobMatcher` in `SwiftStaticAnalysisCore`. Retained as a thin
    /// alias so callers inside this file read naturally.
    static func matchesGlobPattern(_ path: String, pattern: String) -> Bool {
        GlobMatcher.matchesWithFastPaths(path: path, pattern: pattern)
    }

    /// Maximum size of an individual file we will scan for line count in
    /// `getCodebaseInfo`. Files larger than this still contribute to
    /// `totalBytes` (via the directory metadata) but not to `totalLines` —
    /// we refuse to mmap the file to avoid pinning hundreds of megabytes
    /// behind a single MCP call.
    static let getCodebaseInfoMaxScanBytes: UInt64 = 64 * 1024 * 1024  // 64 MiB

    /// Maximum cumulative bytes the line-counting pass will mmap across
    /// the whole codebase. A repository with 10 000 source files at the
    /// per-file ceiling (640 GiB worst-case sequential mmap) would
    /// otherwise pin the MCP server in a single `get_codebase_info`
    /// call. We cap at 4 GiB and return a partial line total when the
    /// ceiling is hit — the byte total stays accurate.
    static let getCodebaseInfoMaxAggregateBytes: UInt64 = 4 * 1024 * 1024 * 1024  // 4 GiB

    /// Returns information about the codebase.
    public func getCodebaseInfo() throws -> CodebaseInfo {
        let swiftFiles = try findSwiftFiles()

        var totalLines = 0
        var totalBytes: UInt64 = 0
        var scannedBytes: UInt64 = 0

        let fileManager = FileManager.default
        for file in swiftFiles {
            let fileSize: UInt64
            if let attributes = try? fileManager.attributesOfItem(atPath: file),
                let size = attributes[.size] as? UInt64
            {
                totalBytes += size
                fileSize = size
            } else {
                continue
            }

            // Skip line counting on pathologically large files. The byte
            // total is already recorded; spending wall-clock and address
            // space on a 200 MiB generated Swift file is not worth it for
            // an MCP `get_codebase_info` call.
            guard fileSize > 0, fileSize <= Self.getCodebaseInfoMaxScanBytes else {
                continue
            }

            // Cumulative ceiling: once we've scanned `maxAggregateBytes`
            // worth of source, stop counting lines. The remaining files
            // still contribute to `totalBytes` (already recorded above);
            // `totalLines` becomes a partial figure.
            if scannedBytes >= Self.getCodebaseInfoMaxAggregateBytes {
                continue
            }

            // Use memory-mapped I/O + raw-span byte scan rather than
            // `String(contentsOfFile:)` so a 116-file codebase doesn't
            // allocate 116 fresh UTF-8 strings just to count newlines.
            // The heap allocation shows up in MCP latency profiles for
            // large fixtures.
            guard let mapped = try? MemoryMappedFile(path: file) else { continue }
            let newlines = mapped.withRawSpan { span -> Int in
                var count = 0
                for index in 0..<span.byteCount {
                    if span.unsafeLoad(fromByteOffset: index, as: UInt8.self) == 0x0A {
                        count &+= 1
                    }
                }
                return count
            }
            totalLines += newlines + 1
            scannedBytes += fileSize
        }

        return CodebaseInfo(
            rootPath: rootPath,
            swiftFileCount: swiftFiles.count,
            totalLines: totalLines,
            totalBytes: totalBytes
        )
    }
}

/// Errors that can occur when working with the codebase context.
public enum CodebaseContextError: Error, LocalizedError, Sendable {
    case invalidRootPath(String)
    case pathOutsideSandbox(String, allowedRoot: String)
    case enumerationFailed(String)
    case noCodebaseSpecified

    public var errorDescription: String? {
        // Attacker-controlled paths reach these error descriptions
        // through MCP. Sanitise C0 control bytes (newlines, ANSI ESC,
        // etc.) before embedding so a hostile path cannot inject log
        // breaks or terminal escape sequences into stderr (CWE-117).
        switch self {
        case .invalidRootPath(let path):
            return
                "Invalid root path: '\(PathUtilities.sanitizedForDiagnostic(path))' does not exist or is not a directory"
        case .pathOutsideSandbox(let path, let root):
            return
                "Path '\(PathUtilities.sanitizedForDiagnostic(path))' is outside the allowed sandbox: '\(PathUtilities.sanitizedForDiagnostic(root))'"
        case .enumerationFailed(let path):
            return "Failed to enumerate files in: '\(PathUtilities.sanitizedForDiagnostic(path))'"
        case .noCodebaseSpecified:
            return
                "No codebase path specified. Please provide 'codebase_path' parameter or start the server with a default path."
        }
    }
}

/// Information about a codebase.
public struct CodebaseInfo: Sendable, Codable {
    public let rootPath: String
    public let swiftFileCount: Int
    public let totalLines: Int
    public let totalBytes: UInt64

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }
}
