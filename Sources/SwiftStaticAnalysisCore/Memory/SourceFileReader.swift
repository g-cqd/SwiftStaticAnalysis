//  SourceFileReader.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - SourceFileReader

/// Centralised entry point for reading Swift source text.
///
/// Uses `MemoryMappedFile` for files at or above `mmapThreshold` and falls
/// back to `String(contentsOfFile:encoding:)` for smaller files where the
/// `mmap`/`munmap`/`fstat` syscall overhead outweighs the win. The same
/// helper backs `SwiftFileParser`, the duplication detectors, and the symbol
/// context extractor so the README's "Memory-Mapped I/O" claim corresponds
/// to actual production behaviour.
///
/// Calls inherit `MemoryMappedFile`'s safety guards: regular-file check
/// (`S_IFREG`), size cap (default 256 MiB), `O_NOFOLLOW` on Darwin.
public enum SourceFileReader {
    /// Files at or above this size are read via `mmap`. The default 4 KiB
    /// approximates a page boundary and matches the typical breakpoint where
    /// `mmap` overhead is amortised by the page-cache win.
    public static let defaultMmapThreshold: Int = 4 * 1024

    /// Read a UTF-8 text file, optionally via memory mapping.
    ///
    /// - Parameters:
    ///   - path: Absolute filesystem path.
    ///   - mmapThreshold: File-size threshold (bytes) above which `mmap` is
    ///     used. Pass `.max` to force the conventional `String(contentsOfFile:)`
    ///     path; pass `0` to always use `mmap`.
    /// - Returns: The decoded UTF-8 source.
    /// - Throws: `MemoryMappedFileError` or any error raised by Foundation's
    ///   string-from-file APIs.
    public static func readSource(
        at path: String,
        mmapThreshold: Int = defaultMmapThreshold
    ) throws -> String {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            // Fall back to `String(contentsOfFile:)` so we surface its
            // diagnostic ("file not found", "permission denied", etc.)
            // instead of a confusing mmap error.
            return try String(contentsOfFile: path, encoding: .utf8)
        }

        let size = (attributes[.size] as? Int) ?? 0
        if size == 0 {
            return ""
        }
        if size >= mmapThreshold {
            let mapped = try MemoryMappedFile(path: path)
            return mapped.readAsString() ?? ""
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Read a UTF-8 text file and split it into lines.
    ///
    /// For files at or above `mmapThreshold` this avoids the
    /// `String.components(separatedBy: "\n")` pass by deriving line ranges
    /// from `MemoryMappedFile.findLineRanges()` (memoised) and slicing the
    /// underlying mapping.
    ///
    /// - Returns: An array of line strings (no trailing newline characters).
    public static func readLines(
        at path: String,
        mmapThreshold: Int = defaultMmapThreshold
    ) throws -> [String] {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            return source.components(separatedBy: "\n")
        }

        let size = (attributes[.size] as? Int) ?? 0
        if size == 0 {
            return []
        }
        if size >= mmapThreshold, let mapped = try? MemoryMappedFile(path: path) {
            let ranges = mapped.findLineRanges()
            var lines: [String] = []
            lines.reserveCapacity(ranges.count)
            for range in ranges {
                lines.append(mapped.slice(offset: range.offset, length: range.length).asString() ?? "")
            }
            return lines
        }
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return source.components(separatedBy: "\n")
    }
}
