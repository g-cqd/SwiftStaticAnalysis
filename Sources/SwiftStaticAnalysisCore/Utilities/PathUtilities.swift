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

    /// Strip terminal-control bytes from a path string before embedding
    /// it in a user-facing diagnostic. Drops C0 control bytes
    /// (`0x00...0x1F`) except `\t`, plus DEL (`0x7F`) — these otherwise
    /// allow a hostile path to inject ANSI escape sequences or
    /// newline-based line breaks into stderr / log output (log
    /// injection, CWE-117).
    public static func sanitizedForDiagnostic(_ path: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(path.unicodeScalars.count)
        for scalar in path.unicodeScalars {
            let value = scalar.value
            if value < 0x20, value != 0x09 {
                result.append(UnicodeScalar(0xFFFD)!)
            } else if value == 0x7F {
                result.append(UnicodeScalar(0xFFFD)!)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
