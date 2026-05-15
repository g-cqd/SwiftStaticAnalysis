//  MemoryMappedFile.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Synchronization
import SystemPackage

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - MemoryMappedFileError

/// Errors that can occur during memory mapping.
/// Exhaustive error handling for memory operations. // swa:ignore-unused-cases
public enum MemoryMappedFileError: Error, Sendable {
    case fileNotFound(String)
    case mappingFailed(String, Int32)
    case invalidRange
    case fileEmpty
    /// The path resolves to a non-regular file (FIFO, device, socket, directory).
    /// Memory-mapping such targets either blocks indefinitely (FIFO) or reads
    /// unbounded data (`/dev/zero`).
    case notRegularFile(String)
    /// The file exceeds the configured size cap.
    case fileTooLarge(String, size: Int, limit: Int)
}

// MARK: - MappingStorage (private @unchecked Sendable cage)

/// Owns the raw mmap pointer and the swift-system `FileDescriptor`.
///
/// This is the only type in the memory layer that carries
/// `@unchecked Sendable`. The compiler can't prove a `UnsafeRawPointer`
/// is safe to share across threads, but the mmap'd region is read-only
/// (`PROT_READ`), immutable after init, and lives for the storage's
/// lifetime — so the guarantee is real, just not statically checkable.
/// We cage it inside a `private final class` rather than exposing the
/// unchecked attribute on the public `MemoryMappedFile` / `FileSlice`
/// types.
private final class MappingStorage: @unchecked Sendable {
    let path: String
    let size: Int
    let data: UnsafeRawPointer
    let descriptor: FileDescriptor

    init(path: String, size: Int, data: UnsafeRawPointer, descriptor: FileDescriptor) {
        self.path = path
        self.size = size
        self.data = data
        self.descriptor = descriptor
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: data), size)
        do {
            try descriptor.close()
        } catch {
            // Surface descriptor-close failures so file-table exhaustion
            // under load is observable rather than silent. We can't
            // `throw` from `deinit`, so the log is the only signal —
            // suppressing it would let an EBADF / EIO run accumulate
            // until the process can't open more files.
            MappingStorage.deinitLogger.warning(
                "MemoryMappedFile descriptor close failed for \(self.path): \(error)"
            )
        }
    }

    /// Dedicated logger for the closing side. The `os.Logger` instance
    /// itself is `Sendable` (it's a value wrapper around an OSLog
    /// handle), so it composes with the storage class's safety story.
    private static let deinitLogger = AnalysisLogger.osLog(category: "MemoryMappedFile")
}

// MARK: - MemoryMappedFile

/// A memory-mapped file for zero-copy read access.
///
/// Memory mapping allows the operating system to map a file directly into
/// the process's address space. Reads are performed directly from the
/// kernel's page cache without additional copying.
///
/// `MemoryMappedFile` is plain `Sendable`. The `UnsafeRawPointer` to the
/// mmap region is held by a private `MappingStorage` class that internally
/// carries `@unchecked Sendable` — the standard cage pattern. The file
/// descriptor is a `SystemPackage.FileDescriptor`, so open/close use typed
/// errors.
///
/// All public access goes through `RawSpan` (via `withRawSpan`),
/// `readAsString(offset:length:)`, or `readBytes(offset:length:)`. All
/// are read-only.
///
/// Example:
/// ```swift
/// let mmf = try MemoryMappedFile(path: "/path/to/file.swift")
/// let slice = mmf.slice(offset: 0, length: 100)
/// let text = slice.asString()
/// ```
public final class MemoryMappedFile: Sendable {
    // MARK: Lifecycle

    /// Default upper bound for the file size accepted by `init(path:)`.
    /// 256 MiB is enough for the largest Swift sources seen in practice and
    /// caps the worst-case CPU cost of full-file scans (`findLineRanges`).
    public static let defaultSizeLimit: Int = 256 * 1024 * 1024

    /// Initialize a memory-mapped file.
    ///
    /// Rejects non-regular files (FIFOs, devices, sockets) and files larger
    /// than `sizeLimit`. The previous implementation would happily map
    /// `/dev/zero`, leading to a multi-gigabyte byte scan in `findLineRanges`.
    ///
    /// The file descriptor is opened via `FileDescriptor.open` (swift-system)
    /// with `.noFollow` — symlinks at the final path component are rejected
    /// at the kernel boundary, so `MCP` callers that have already validated
    /// the canonical path get belt-and-braces protection against TOCTOU
    /// symlink swaps. `.noFollow` resolves to `O_NOFOLLOW` on both Darwin
    /// and Linux; the `mmap` / `munmap` calls below are platform-guarded
    /// (`#if canImport(Darwin)` / `#elseif canImport(Glibc)`) but the
    /// Linux configuration has no CI coverage today.
    ///
    /// - Parameters:
    ///   - path: Path to the file to map.
    ///   - sizeLimit: Maximum mapping size in bytes. Defaults to
    ///     `MemoryMappedFile.defaultSizeLimit` (256 MiB).
    /// - Throws: `MemoryMappedFileError` if the file is missing, not a
    ///   regular file, empty, larger than `sizeLimit`, or cannot be mapped.
    public init(path: String, sizeLimit: Int = MemoryMappedFile.defaultSizeLimit)
        throws(MemoryMappedFileError)
    {
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                FilePath(path),
                .readOnly,
                options: [.noFollow]
            )
        } catch {
            throw MemoryMappedFileError.fileNotFound(path)
        }

        var statBuf = stat()
        guard fstat(descriptor.rawValue, &statBuf) == 0 else {
            try? descriptor.close()
            throw MemoryMappedFileError.mappingFailed(path, errno)
        }

        // Reject anything that isn't a regular file. `S_IFMT` masks out the
        // permission bits so we can compare against the file-type constants.
        guard (statBuf.st_mode & S_IFMT) == S_IFREG else {
            try? descriptor.close()
            throw MemoryMappedFileError.notRegularFile(path)
        }

        let fileSize = Int(statBuf.st_size)

        guard fileSize > 0 else {
            try? descriptor.close()
            throw MemoryMappedFileError.fileEmpty
        }

        guard fileSize <= sizeLimit else {
            try? descriptor.close()
            throw MemoryMappedFileError.fileTooLarge(path, size: fileSize, limit: sizeLimit)
        }

        let mapped = mmap(
            nil,
            fileSize,
            PROT_READ,
            MAP_PRIVATE,
            descriptor.rawValue,
            0,
        )

        guard mapped != MAP_FAILED, let mappedPointer = mapped else {
            try? descriptor.close()
            throw MemoryMappedFileError.mappingFailed(path, errno)
        }

        let rawData = UnsafeRawPointer(mappedPointer)
        madvise(UnsafeMutableRawPointer(mutating: rawData), fileSize, MADV_SEQUENTIAL)

        self.storage = MappingStorage(
            path: path,
            size: fileSize,
            data: rawData,
            descriptor: descriptor
        )
    }

    // MARK: Public

    /// Path to the mapped file.
    public var path: String { storage.path }

    /// Size of the file in bytes.
    public var size: Int { storage.size }

    /// Pointer to the mapped memory. Held by the private storage class
    /// so the only `@unchecked Sendable` in this layer is one private
    /// type, not the public `MemoryMappedFile` type.
    private var data: UnsafeRawPointer { storage.data }

    /// Borrow the entire mapping as a `RawSpan`.
    ///
    /// The closure receives a lifetime-bounded view of the mapped bytes.
    /// `RawSpan` is `~Escapable`, so the compiler will refuse to let the
    /// view escape past the file's lifetime.
    public func withRawSpan<T>(_ body: (RawSpan) throws -> T) rethrows -> T {
        let buffer = UnsafeRawBufferPointer(start: data, count: size)
        let span = RawSpan(_unsafeBytes: buffer)
        return try body(span)
    }

    /// Borrow a sub-range of the mapping as a `RawSpan`. Out-of-range
    /// offsets / lengths are clamped to the file bounds — never traps.
    public func withRawSpan<T>(
        offset: Int,
        length: Int,
        _ body: (RawSpan) throws -> T
    ) rethrows -> T {
        let validOffset = max(0, min(offset, size))
        let validLength = min(length, size - validOffset)
        let buffer = UnsafeRawBufferPointer(start: data.advanced(by: validOffset), count: validLength)
        let span = RawSpan(_unsafeBytes: buffer)
        return try body(span)
    }

    // MARK: - Access

    /// Get a byte at the given offset.
    ///
    /// - Parameter offset: Byte offset.
    /// - Returns: The byte value, or nil if out of range.
    public subscript(offset: Int) -> UInt8? {
        guard offset >= 0, offset < size else { return nil }
        return data.load(fromByteOffset: offset, as: UInt8.self)
    }

    /// Get bytes in a range.
    ///
    /// - Parameter range: Byte range.
    /// - Returns: Array of bytes.
    public subscript(range: Range<Int>) -> [UInt8] {
        let start = max(0, range.lowerBound)
        let end = min(size, range.upperBound)
        guard start < end else { return [] }

        let length = end - start
        var result = [UInt8](repeating: 0, count: length)
        result.withUnsafeMutableBytes { buffer in
            buffer.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: data.advanced(by: start),
                    count: length,
                ))
        }
        return result
    }

    /// Read the entire file as a string.
    ///
    /// Note: This creates a copy. Use `withRawSpan(_:)` for zero-copy
    /// access.
    public func readAsString() -> String? {
        readAsString(offset: 0, length: size)
    }

    /// Read a range as a string. Out-of-range offsets / lengths are
    /// clamped to the file bounds.
    public func readAsString(offset: Int, length: Int) -> String? {
        let validOffset = max(0, min(offset, size))
        let validLength = min(length, size - validOffset)
        guard validLength > 0 else { return "" }
        let buffer = UnsafeBufferPointer(
            start: data.advanced(by: validOffset).assumingMemoryBound(to: UInt8.self),
            count: validLength
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Read the entire file as a byte array (creates a copy).
    public func readBytes() -> [UInt8] {
        readBytes(offset: 0, length: size)
    }

    /// Read a range as a byte array (creates a copy). Out-of-range
    /// offsets / lengths are clamped to the file bounds.
    public func readBytes(offset: Int, length: Int) -> [UInt8] {
        let validOffset = max(0, min(offset, size))
        let validLength = min(length, size - validOffset)
        guard validLength > 0 else { return [] }
        var result = [UInt8](repeating: 0, count: validLength)
        let base = data.advanced(by: validOffset)
        result.withUnsafeMutableBytes { dest in
            dest.copyMemory(from: UnsafeRawBufferPointer(start: base, count: validLength))
        }
        return result
    }

    // MARK: - Line Access

    /// Find line boundaries in the file.
    ///
    /// The first call performs a full byte scan; subsequent calls reuse the
    /// cached result. A `Mutex` from `Synchronization` serialises lazy
    /// construction without paying the cost of a `DispatchQueue`. The
    /// pointer and size are snapshotted to local `let`s at the top of the
    /// closure so the per-byte loop body doesn't traverse the `storage`
    /// class indirection on every load — without the snapshot the compiler
    /// can't elide the per-iteration class-field reload.
    ///
    /// - Returns: Array of (offset, length) tuples for each line.
    public func findLineRanges() -> [(offset: Int, length: Int)] {
        lineRangesLock.withLock { cache in
            if let cached = cache {
                return cached
            }
            let data = storage.data
            let size = storage.size
            var ranges: [(Int, Int)] = []
            ranges.reserveCapacity(max(8, size / 32))
            var lineStart = 0

            for i in 0..<size where data.load(fromByteOffset: i, as: UInt8.self) == 0x0A {
                ranges.append((lineStart, i - lineStart))
                lineStart = i + 1
            }

            if lineStart < size {
                ranges.append((lineStart, size - lineStart))
            }

            cache = ranges
            return ranges
        }
    }

    /// Get the contents of a specific line (0-indexed) as a string.
    ///
    /// - Parameter lineIndex: Line index (0-based).
    /// - Returns: The line content, or nil if out of range.
    public func line(_ lineIndex: Int) -> String? {
        let ranges = findLineRanges()
        guard lineIndex >= 0, lineIndex < ranges.count else { return nil }
        let range = ranges[lineIndex]
        return readAsString(offset: range.offset, length: range.length)
    }

    // MARK: - Prefetch

    /// Prefetch a range of the file into memory.
    ///
    /// This hints to the kernel that the specified range will be accessed soon.
    ///
    /// - Parameters:
    ///   - offset: Starting offset.
    ///   - length: Number of bytes to prefetch.
    public func prefetch(offset: Int, length: Int) {
        let validOffset = max(0, min(offset, size))
        let validLength = min(length, size - validOffset)
        madvise(
            UnsafeMutableRawPointer(mutating: data.advanced(by: validOffset)),
            validLength,
            MADV_WILLNEED,
        )
    }

    /// Advise the kernel that we're done with a range.
    ///
    /// This hints that the pages can be reclaimed if memory is needed.
    ///
    /// - Parameters:
    ///   - offset: Starting offset.
    ///   - length: Number of bytes.
    public func dontneed(offset: Int, length: Int) {
        let validOffset = max(0, min(offset, size))
        let validLength = min(length, size - validOffset)
        madvise(
            UnsafeMutableRawPointer(mutating: data.advanced(by: validOffset)),
            validLength,
            MADV_DONTNEED,
        )
    }

    // MARK: Private

    /// Cached line ranges, lazily computed by `findLineRanges` and guarded
    /// by `Synchronization.Mutex`. The mutex is lighter than the previous
    /// `DispatchQueue` and is the project's standard concurrency primitive.
    private let lineRangesLock: Mutex<[(offset: Int, length: Int)]?> = Mutex(nil)

    /// Backing storage. Owning the unsafe pointer + descriptor here lets
    /// `MemoryMappedFile` itself drop `@unchecked Sendable` — the
    /// unchecked attribute is now confined to `MappingStorage`.
    private let storage: MappingStorage
}

// MARK: - TokenSlice

/// A slice-based token representation using offsets into a memory-mapped file.
///
/// This allows tokens to reference source text without copying strings.
public struct TokenSlice: Sendable, Hashable {
    // MARK: Lifecycle

    public init(offset: Int, length: Int, line: Int, column: Int) {
        self.offset = offset
        self.length = length
        self.line = line
        self.column = column
    }

    // MARK: Public

    /// Offset in the source file.
    public let offset: Int

    /// Length in bytes.
    public let length: Int

    /// Line number (1-based).
    public let line: Int

    /// Column number (1-based).
    public let column: Int

    /// Get the token text from a memory-mapped file.
    public func text(from file: MemoryMappedFile) -> String? {
        file.readAsString(offset: offset, length: length)
    }
}

// MARK: - SliceBasedTokenSequence

/// A token sequence using slices instead of copied strings.
///
/// This provides the same interface as TokenSequence but stores only
/// offsets, reducing memory usage significantly for large files.
public struct SliceBasedTokenSequence: Sendable {
    // MARK: Lifecycle

    public init(file: String, source: MemoryMappedFile, tokens: [TokenSlice], kinds: [UInt8]) {
        self.file = file
        self.source = source
        self.tokens = tokens
        self.kinds = kinds
    }

    // MARK: Public

    /// The source file path.
    public let file: String

    /// Memory-mapped source file.
    public let source: MemoryMappedFile

    /// Token slices in order.
    public let tokens: [TokenSlice]

    /// Token kinds in order (parallel array).
    public let kinds: [UInt8]

    /// Number of tokens.
    public var count: Int { tokens.count }

    /// Get text for a token at index.
    public func text(at index: Int) -> String? {
        guard index >= 0, index < tokens.count else { return nil }
        return tokens[index].text(from: source)
    }

    /// Extract a code snippet for the given line range.
    public func snippet(startLine: Int, endLine: Int) -> String? {
        // Find byte range for lines
        let lineRanges = source.findLineRanges()
        let start = max(0, startLine - 1)
        let end = min(lineRanges.count, endLine)

        guard start < end, start < lineRanges.count else { return nil }

        let startOffset = lineRanges[start].offset
        let endRange = lineRanges[end - 1]
        let length = endRange.offset + endRange.length - startOffset

        return source.readAsString(offset: startOffset, length: length)
    }
}
