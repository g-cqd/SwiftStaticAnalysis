//  PathUtilities.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

/// Path manipulation helpers that avoid the legacy `NSString` bridge.
public enum PathUtilities {
    /// Expand a leading `~` or `~/` to the user's home directory.
    ///
    /// Returns the input unchanged if it does not begin with `~`.
    public static func expandingTildeInPath(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst())
        }
        // `~user` form (rarely used) — fall back to NSString bridge which
        // knows how to look up other users' home directories.
        return (path as NSString).expandingTildeInPath
    }

    /// Canonicalise a path: resolve symlinks, then `.` / `..` / aliases.
    ///
    /// Returns the canonical absolute path. Useful for sandbox boundary checks.
    public static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: expandingTildeInPath(path))
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    /// Make `path` absolute relative to `base`, then canonicalise it.
    public static func canonicalize(_ path: String, relativeTo base: URL) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return canonicalize(path)
        }
        return base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
