//  SwiftFileFinder.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SwiftFileFinder

/// Canonical Swift-file enumeration used by the CLI, MCP server, and
/// benchmark runner. Phase 3.1 of the audit-driven cleanup consolidates
/// three previously-divergent implementations
/// (`swa/FileDiscovery.findSwiftFiles`,
/// `SwiftStaticAnalysisMCP.CodebaseContext.findSwiftFiles`,
/// `swa-bench/main.findSwiftFiles`) so symlink-escape hygiene, default
/// excluded directories, and glob handling don't drift between modules.
///
/// Two presets cover the existing call shapes:
/// - ``Options/strict`` — the CLI/MCP behaviour. Canonicalises every
///   discovered path, refuses anything that resolves outside the root,
///   honours a default deny list of build directories, respects glob
///   exclusions through ``GlobMatcher/matchesWithFastPaths``.
/// - ``Options/fast`` — the benchmark behaviour. Minimal: enumerate
///   `.swift` files only, no canonicalisation, no exclusions.
///
/// Callers in `swa/`, `SwiftStaticAnalysisMCP/`, and `swa-bench/`
/// continue to expose a thin façade for source-compat; under the hood
/// every Swift-file enumeration in the project lands here.
public struct SwiftFileFinder: Sendable {
    public init(options: Options = .strict) {
        self.options = options
    }

    public let options: Options

    // MARK: - Options

    public struct Options: Sendable {
        public init(
            confineToRoot: Bool,
            defaultExcludedDirectories: Set<String>,
            respectExcludeGlobs: Bool
        ) {
            self.confineToRoot = confineToRoot
            self.defaultExcludedDirectories = defaultExcludedDirectories
            self.respectExcludeGlobs = respectExcludeGlobs
        }

        /// When `true`, every discovered file's canonical path must
        /// resolve back under the input root (or be the input root
        /// itself). A symlink pointing at `/etc/passwd` is silently
        /// dropped. Disabled in ``fast``.
        public let confineToRoot: Bool

        /// Directories that are always skipped, even when they're not
        /// hidden (e.g. `.build`, `Pods`).
        public let defaultExcludedDirectories: Set<String>

        /// When `true`, the caller-supplied `excludePaths` glob list is
        /// honoured. ``fast`` ignores it.
        public let respectExcludeGlobs: Bool

        /// Default excluded directories — build artefacts, dependency
        /// vendoring, source-control metadata.
        public static let defaultExcluded: Set<String> = [
            ".build",
            "Build",
            "DerivedData",
            ".swiftpm",
            "Pods",
            "Carthage",
            ".git",
        ]

        /// Strict hygiene preset. Used by the CLI and the MCP server —
        /// any path that resolves outside the input root is silently
        /// dropped; the default deny list applies; user-supplied
        /// `excludePaths` globs are honoured.
        public static let strict = Options(
            confineToRoot: true,
            defaultExcludedDirectories: defaultExcluded,
            respectExcludeGlobs: true
        )

        /// Minimal preset. Used by the benchmark runner. Enumerates
        /// `.swift` files under the root with no hygiene checks; runs
        /// fastest, accepts symlinks freely, and ignores exclusion
        /// patterns. Don't use this against attacker-controlled input.
        public static let fast = Options(
            confineToRoot: false,
            defaultExcludedDirectories: [],
            respectExcludeGlobs: false
        )
    }

    // MARK: - Lookup

    /// Enumerate Swift files under the given paths.
    ///
    /// Returns a sorted array of canonical absolute paths. Each input
    /// path may be either a directory (recursed into) or a single
    /// `.swift` file (returned as-is after the same hygiene gates). A
    /// non-existent path throws ``AnalysisError/fileNotFound(_:)``; a
    /// non-`.swift` single file throws ``AnalysisError/invalidPath(_:)``.
    public func find(
        in paths: [String], excludePaths: [String] = []
    ) throws -> [String] {
        var swiftFiles: [String] = []
        let fileManager = FileManager.default
        let activeExcludes = options.respectExcludeGlobs ? excludePaths : []

        for path in paths {
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
                guard canonicalPath.hasSuffix(".swift") else {
                    throw AnalysisError.invalidPath("Not a Swift file: \(canonicalPath)")
                }
                if !activeExcludes.isEmpty,
                    activeExcludes.contains(where: { GlobMatcher.matchesWithFastPaths(path: canonicalPath, pattern: $0) })
                {
                    continue
                }
                swiftFiles.append(canonicalPath)
                continue
            }

            try enumerate(
                directory: url,
                rootCanonical: canonicalPath,
                excludePatterns: activeExcludes,
                into: &swiftFiles
            )
        }

        return swiftFiles.sorted()
    }

    private func enumerate(
        directory url: URL,
        rootCanonical: String,
        excludePatterns: [String],
        into swiftFiles: inout [String]
    ) throws {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        let rootPrefix = rootCanonical.hasSuffix("/") ? rootCanonical : rootCanonical + "/"

        for case let fileURL as URL in enumerator {
            // Default-excluded directory gate — applied to every path
            // component so an excluded ancestor short-circuits its
            // descendants too.
            let components = fileURL.pathComponents
            if components.contains(where: { options.defaultExcludedDirectories.contains($0) }) {
                continue
            }
            guard fileURL.pathExtension == "swift" else { continue }

            let resolvedPath: String
            if options.confineToRoot {
                let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == rootCanonical || resolved.hasPrefix(rootPrefix) else {
                    continue
                }
                resolvedPath = resolved
            } else {
                resolvedPath = fileURL.path
            }

            if !excludePatterns.isEmpty,
                excludePatterns.contains(where: { GlobMatcher.matchesWithFastPaths(path: resolvedPath, pattern: $0) })
            {
                continue
            }
            swiftFiles.append(resolvedPath)
        }
    }
}
