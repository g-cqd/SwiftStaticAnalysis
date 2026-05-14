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
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
        else {
            throw CodebaseContextError.enumerationFailed(rootPath)
        }

        var swiftFiles: [String] = []

        for case let fileURL as URL in enumerator {
            let relativePath = String(fileURL.path.dropFirst(rootPath.count + 1))

            // Check exclude patterns
            let shouldExclude = excludePatterns.contains { pattern in
                Self.matchesGlobPattern(relativePath, pattern: pattern)
            }

            if shouldExclude {
                if fileURL.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard fileURL.pathExtension == "swift" else { continue }

            // Reject symlinks whose target escapes the sandbox. The enumerator
            // follows symlinks by default; we explicitly canonicalise each
            // candidate and re-check it against the root.
            let canonical = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonical == rootPath || canonical.hasPrefix(rootPath + "/") else { continue }

            swiftFiles.append(canonical)
        }

        return swiftFiles.sorted()
    }

    /// Simple glob pattern matching (supports * and **).
    static func matchesGlobPattern(_ path: String, pattern: String) -> Bool {
        // Escape regex metacharacters that aren't part of the glob alphabet,
        // then translate the three glob tokens. The previous implementation
        // only escaped `.`, which let `+`, `(`, `[`, `?`, `^`, `$`, `|`, `\`
        // leak through as regex syntax.
        var escaped = ""
        escaped.reserveCapacity(pattern.count * 2)
        for character in pattern {
            switch character {
            case "*":
                escaped.append("*")  // handled below
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\", "?":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        let regexPattern =
            escaped
            .replacingOccurrences(of: "**/", with: "(.*/)?")
            .replacingOccurrences(of: "**", with: ".*")
            .replacingOccurrences(of: "*", with: "[^/]*")

        guard let regex = try? Regex("^\(regexPattern)$") else {
            return false
        }
        return path.wholeMatch(of: regex) != nil
    }

    /// Returns information about the codebase.
    public func getCodebaseInfo() throws -> CodebaseInfo {
        let swiftFiles = try findSwiftFiles()

        var totalLines = 0
        var totalBytes: UInt64 = 0

        let fileManager = FileManager.default
        for file in swiftFiles {
            if let attributes = try? fileManager.attributesOfItem(atPath: file),
                let size = attributes[.size] as? UInt64
            {
                totalBytes += size
            }

            if let content = try? String(contentsOfFile: file, encoding: .utf8) {
                totalLines += content.utf8.lazy.count(where: { $0 == 0x0A }) + 1
            }
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
        switch self {
        case .invalidRootPath(let path):
            return "Invalid root path: '\(path)' does not exist or is not a directory"
        case .pathOutsideSandbox(let path, let root):
            return "Path '\(path)' is outside the allowed sandbox: '\(root)'"
        case .enumerationFailed(let path):
            return "Failed to enumerate files in: '\(path)'"
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
