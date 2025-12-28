//
//  MemoryMappedFile.swift
//  SwiftStaticAnalysis
//
//  Memory-mapped file I/O for zero-copy file access.
//
//  Memory mapping allows reading files directly from the kernel's page cache
//  without copying data to userspace buffers. This is especially efficient
//  for large files that are read sequentially or with random access.
//
//  Benefits:
//  - Zero-copy access (no memcpy from kernel to userspace)
//  - Lazy loading (pages loaded on-demand)
//  - Automatic memory management (kernel handles paging)
//  - Efficient for read-only access patterns
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Memory Mapped File Error

/// Errors that can occur during memory mapping.
public enum MemoryMappedFileError: Error, Sendable {
    case fileNotFound(String)
    case mappingFailed(String, Int32)
    case invalidRange
    case fileEmpty
}

// MARK: - Memory Mapped File

/// A memory-mapped file for zero-copy read access.
///
/// Memory mapping allows the operating system to map a file directly into
/// the process's address space. Reads are performed directly from the
/// kernel's page cache without additional copying.
///
/// Thread Safety: The mapping itself is thread-safe for reads. Multiple
/// threads can read from the same mapping concurrently.
///
/// Example:
/// ```swift
/// let mmf = try MemoryMappedFile(path: "/path/to/file.swift")
/// let slice = mmf.slice(offset: 0, length: 100)
/// let text = slice.asString()
/// ```
public final class MemoryMappedFile: @unchecked Sendable {
    /// Path to the mapped file.
    public let path: String

    /// Size of the file in bytes.
    public let size: Int

    /// Pointer to the mapped memory.
    private let data: UnsafeRawPointer

    /// File descriptor (kept open for the mapping).
    private let fileDescriptor: Int32

    /// Initialize a memory-mapped file.
    ///
    /// - Parameter path: Path to the file to map.
    /// - Throws: `MemoryMappedFileError` if the file cannot be mapped.
    public init(path: String) throws {
        self.path = path

        // Open the file
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw MemoryMappedFileError.fileNotFound(path)
        }
        self.fileDescriptor = fd

        // Get file size
        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0 else {
            close(fd)
            throw MemoryMappedFileError.mappingFailed(path, errno)
        }
        self.size = Int(statBuf.st_size)

        guard size > 0 else {
            close(fd)
            throw MemoryMappedFileError.fileEmpty
        }

        // Map the file
        let mapped = mmap(
            nil,
            size,
            PROT_READ,
            MAP_PRIVATE,
            fd,
            0
        )

        guard mapped != MAP_FAILED else {
            close(fd)
            throw MemoryMappedFileError.mappingFailed(path, errno)
        }

        self.data = UnsafeRawPointer(mapped!)

        // Advise the kernel about our access pattern (sequential)
        madvise(UnsafeMutableRawPointer(mutating: data), size, MADV_SEQUENTIAL)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: data), size)
        close(fileDescriptor)
    }

    // MARK: - Access

    /// Get a slice of the mapped file.
    ///
    /// - Parameters:
    ///   - offset: Starting offset in bytes.
    ///   - length: Number of bytes to include.
    /// - Returns: A slice representing the byte range.
    public func slice(offset: Int, length: Int) -> FileSlice {
        let validOffset = max(0, min(offset, size))
        let validLength = min(length, size - validOffset)
        return FileSlice(
            base: data.advanced(by: validOffset),
            length: validLength,
            file: self
        )
    }

    /// Get the entire file as a slice.
    public var fullSlice: FileSlice {
        slice(offset: 0, length: size)
    }

    /// Get a byte at the given offset.
    ///
    /// - Parameter offset: Byte offset.
    /// - Returns: The byte value, or nil if out of range.
    public subscript(offset: Int) -> UInt8? {
        guard offset >= 0 && offset < size else { return nil }
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
            buffer.copyMemory(from: UnsafeRawBufferPointer(
                start: data.advanced(by: start),
                count: length
            ))
        }
        return result
    }

    /// Read the entire file as a string.
    ///
    /// Note: This creates a copy. Use slices for zero-copy access.
    public func readAsString() -> String? {
        fullSlice.asString()
    }

    /// Read a range as a string.
    public func readAsString(offset: Int, length: Int) -> String? {
        slice(offset: offset, length: length).asString()
    }

    // MARK: - Line Access

    /// Find line boundaries in the file.
    ///
    /// - Returns: Array of (offset, length) tuples for each line.
    public func findLineRanges() -> [(offset: Int, length: Int)] {
        var ranges: [(Int, Int)] = []
        var lineStart = 0

        for i in 0..<size {
            if data.load(fromByteOffset: i, as: UInt8.self) == 0x0A { // '\n'
                ranges.append((lineStart, i - lineStart))
                lineStart = i + 1
            }
        }

        // Handle last line without newline
        if lineStart < size {
            ranges.append((lineStart, size - lineStart))
        }

        return ranges
    }

    /// Get the contents of a specific line (0-indexed).
    ///
    /// - Parameter lineIndex: Line index (0-based).
    /// - Returns: The line content as a slice, or nil if out of range.
    public func line(_ lineIndex: Int) -> FileSlice? {
        let ranges = findLineRanges()
        guard lineIndex >= 0 && lineIndex < ranges.count else { return nil }
        let range = ranges[lineIndex]
        return slice(offset: range.offset, length: range.length)
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
            MADV_WILLNEED
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
            MADV_DONTNEED
        )
    }
}

// MARK: - File Slice

/// A zero-copy slice of a memory-mapped file.
///
/// Slices reference the underlying mapped memory without copying.
/// They are lightweight and can be created freely.
public struct FileSlice: @unchecked Sendable {
    /// Pointer to the start of the slice.
    private let base: UnsafeRawPointer

    /// Length of the slice in bytes.
    public let length: Int

    /// Reference to the parent file (keeps mapping alive).
    private let file: MemoryMappedFile

    init(base: UnsafeRawPointer, length: Int, file: MemoryMappedFile) {
        self.base = base
        self.length = length
        self.file = file
    }

    /// Check if the slice is empty.
    public var isEmpty: Bool { length == 0 }

    /// Get a byte at the given offset.
    public subscript(offset: Int) -> UInt8? {
        guard offset >= 0 && offset < length else { return nil }
        return base.load(fromByteOffset: offset, as: UInt8.self)
    }

    /// Create a sub-slice.
    public func subslice(offset: Int, length: Int) -> FileSlice {
        let validOffset = max(0, min(offset, self.length))
        let validLength = min(length, self.length - validOffset)
        return FileSlice(
            base: base.advanced(by: validOffset),
            length: validLength,
            file: file
        )
    }

    /// Convert to a String (creates a copy).
    public func asString() -> String? {
        guard length > 0 else { return "" }
        let buffer = UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: length
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Convert to a byte array (creates a copy).
    public func asBytes() -> [UInt8] {
        guard length > 0 else { return [] }
        var result = [UInt8](repeating: 0, count: length)
        result.withUnsafeMutableBytes { dest in
            dest.copyMemory(from: UnsafeRawBufferPointer(start: base, count: length))
        }
        return result
    }

    /// Get a raw buffer pointer (zero-copy).
    public func asRawBuffer() -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: base, count: length)
    }

    /// Compare with another slice for equality.
    public func equals(_ other: FileSlice) -> Bool {
        guard length == other.length else { return false }
        return memcmp(base, other.base, length) == 0
    }

    /// Compare with a string.
    public func equals(_ string: String) -> Bool {
        guard let str = asString() else { return false }
        return str == string
    }

    /// Hash the slice contents.
    public func hash() -> UInt64 {
        // FNV-1a hash
        var hash: UInt64 = 14695981039346656037
        for i in 0..<length {
            let byte = base.load(fromByteOffset: i, as: UInt8.self)
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }
}

// MARK: - Token Slice

/// A slice-based token representation using offsets into a memory-mapped file.
///
/// This allows tokens to reference source text without copying strings.
public struct TokenSlice: Sendable, Hashable {
    /// Offset in the source file.
    public let offset: Int

    /// Length in bytes.
    public let length: Int

    /// Line number (1-based).
    public let line: Int

    /// Column number (1-based).
    public let column: Int

    public init(offset: Int, length: Int, line: Int, column: Int) {
        self.offset = offset
        self.length = length
        self.line = line
        self.column = column
    }

    /// Get the token text from a memory-mapped file.
    public func text(from file: MemoryMappedFile) -> String? {
        file.slice(offset: offset, length: length).asString()
    }

    /// Get the raw slice from a memory-mapped file.
    public func slice(from file: MemoryMappedFile) -> FileSlice {
        file.slice(offset: offset, length: length)
    }
}

// MARK: - Slice-Based Token Sequence

/// A token sequence using slices instead of copied strings.
///
/// This provides the same interface as TokenSequence but stores only
/// offsets, reducing memory usage significantly for large files.
public struct SliceBasedTokenSequence: Sendable {
    /// The source file path.
    public let file: String

    /// Memory-mapped source file.
    public let source: MemoryMappedFile

    /// Token slices in order.
    public let tokens: [TokenSlice]

    /// Token kinds in order (parallel array).
    public let kinds: [UInt8]

    public init(file: String, source: MemoryMappedFile, tokens: [TokenSlice], kinds: [UInt8]) {
        self.file = file
        self.source = source
        self.tokens = tokens
        self.kinds = kinds
    }

    /// Number of tokens.
    public var count: Int { tokens.count }

    /// Get text for a token at index.
    public func text(at index: Int) -> String? {
        guard index >= 0 && index < tokens.count else { return nil }
        return tokens[index].text(from: source)
    }

    /// Extract a code snippet for the given line range.
    public func snippet(startLine: Int, endLine: Int) -> String? {
        // Find byte range for lines
        let lineRanges = source.findLineRanges()
        let start = max(0, startLine - 1)
        let end = min(lineRanges.count, endLine)

        guard start < end && start < lineRanges.count else { return nil }

        let startOffset = lineRanges[start].offset
        let endRange = lineRanges[end - 1]
        let length = endRange.offset + endRange.length - startOffset

        return source.slice(offset: startOffset, length: length).asString()
    }
}
