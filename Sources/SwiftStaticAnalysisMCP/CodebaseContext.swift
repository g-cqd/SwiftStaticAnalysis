/// CodebaseContext.swift
/// SwiftStaticAnalysisMCP
/// MIT License

import Foundation

/// Manages the sandboxed codebase path and ensures all operations are restricted to it.
public struct CodebaseContext: Sendable {
    /// The root path of the codebase being analyzed.
    public let rootPath: String

    /// The resolved absolute URL of the root path.
    public let rootURL: URL

    /// Initialize with a codebase root path.
    /// - Parameter rootPath: The absolute path to the codebase directory.
    /// - Throws: `CodebaseContextError` if the path is invalid or doesn't exist.
    public init(rootPath: String) throws {
        let expandedPath = NSString(string: rootPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath).standardized

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
    /// - Parameter path: The path to validate.
    /// - Returns: The resolved absolute path if valid.
    /// - Throws: `CodebaseContextError.pathOutsideSandbox` if the path escapes the sandbox.
    public func validatePath(_ path: String) throws -> String {
        let resolvedURL: URL

        if path.hasPrefix("/") {
            // Absolute path
            resolvedURL = URL(fileURLWithPath: path).standardized
        } else {
            // Relative path - resolve against root
            resolvedURL = rootURL.appendingPathComponent(path).standardized
        }

        let resolvedPath = resolvedURL.path

        // Check that the resolved path is within the root
        guard resolvedPath.hasPrefix(rootPath) || resolvedPath == rootPath else {
            throw CodebaseContextError.pathOutsideSandbox(path, allowedRoot: rootPath)
        }

        return resolvedPath
    }

    /// Validates and returns multiple paths within the sandbox.
    /// - Parameter paths: The paths to validate.
    /// - Returns: Array of resolved absolute paths.
    /// - Throws: `CodebaseContextError.pathOutsideSandbox` if any path escapes the sandbox.
    public func validatePaths(_ paths: [String]) throws -> [String] {
        try paths.map { try validatePath($0) }
    }

    /// Returns all Swift files in the codebase.
    /// - Parameter excludePatterns: Glob patterns to exclude (e.g., "**/Tests/**").
    /// - Returns: Array of absolute paths to Swift files.
    public func findSwiftFiles(excludePatterns: [String] = []) throws -> [String] {
        var swiftFiles: [String] = []

        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw CodebaseContextError.enumerationFailed(rootPath)
        }

        for case let fileURL as URL in enumerator {
            let relativePath = String(fileURL.path.dropFirst(rootPath.count + 1))

            // Check exclude patterns
            let shouldExclude = excludePatterns.contains { pattern in
                matchesGlobPattern(relativePath, pattern: pattern)
            }

            if shouldExclude {
                if fileURL.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            if fileURL.pathExtension == "swift" {
                swiftFiles.append(fileURL.path)
            }
        }

        return swiftFiles.sorted()
    }

    /// Simple glob pattern matching (supports * and **).
    private func matchesGlobPattern(_ path: String, pattern: String) -> Bool {
        let regexPattern =
            pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "**/", with: "(.*/)?")
            .replacingOccurrences(of: "**", with: ".*")
            .replacingOccurrences(of: "*", with: "[^/]*")

        guard let regex = try? NSRegularExpression(pattern: "^\(regexPattern)$") else {
            return false
        }

        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
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
                totalLines += content.components(separatedBy: .newlines).count
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
            return "No codebase path specified. Please provide 'codebase_path' parameter or start the server with a default path."
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
