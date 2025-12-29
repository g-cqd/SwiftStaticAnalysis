//
//  SoATokenStorage.swift
//  SwiftStaticAnalysis
//
//  Struct-of-Arrays (SoA) token storage for cache-efficient processing.
//
//  Traditional Array-of-Structs (AoS):
//    tokens: [{kind, offset, length, line}, {kind, offset, length, line}, ...]
//
//  Struct-of-Arrays (SoA):
//    kinds:   [kind, kind, kind, ...]
//    offsets: [offset, offset, offset, ...]
//    lengths: [length, length, length, ...]
//    lines:   [line, line, line, ...]
//
//  Benefits:
//  - Better cache utilization when iterating over a single field
//  - SIMD-friendly contiguous memory layout
//  - Reduced memory for sparse access patterns
//  - Enables vectorized operations on numeric fields
//

import Foundation

// MARK: - TokenKindByte

/// Compact token kind representation using a single byte.
public struct TokenKindByte: RawRepresentable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    // MARK: Public

    public static let keyword = TokenKindByte(rawValue: 0)
    public static let identifier = TokenKindByte(rawValue: 1)
    public static let literal = TokenKindByte(rawValue: 2)
    public static let `operator` = TokenKindByte(rawValue: 3)
    public static let punctuation = TokenKindByte(rawValue: 4)
    public static let unknown = TokenKindByte(rawValue: 5)

    /// Marker for file boundaries in cross-file analysis.
    public static let fileBoundary = TokenKindByte(rawValue: 255)

    public let rawValue: UInt8
}

// MARK: - SoATokenStorage

/// Struct-of-Arrays storage for tokens.
///
/// This layout stores each token field in a separate contiguous array,
/// providing better cache performance for operations that access only
/// specific fields.
///
/// Example:
/// ```swift
/// var storage = SoATokenStorage()
/// storage.append(kind: .keyword, offset: 0, length: 4, line: 1)
/// storage.append(kind: .identifier, offset: 5, length: 3, line: 1)
///
/// // Efficient iteration over kinds only
/// for kind in storage.kinds {
///     // No cache pollution from offset/length/line
/// }
/// ```
public struct SoATokenStorage: Sendable {
    // MARK: Lifecycle

    public init() {
        kinds = []
        offsets = []
        lengths = []
        lines = []
        columns = []
    }

    /// Initialize with pre-allocated capacity.
    public init(capacity: Int) {
        kinds = []
        offsets = []
        lengths = []
        lines = []
        columns = []

        kinds.reserveCapacity(capacity)
        offsets.reserveCapacity(capacity)
        lengths.reserveCapacity(capacity)
        lines.reserveCapacity(capacity)
        columns.reserveCapacity(capacity)
    }

    // MARK: Public

    /// Token kinds (1 byte each).
    public private(set) var kinds: [UInt8]

    /// Byte offsets into source file (4 bytes each).
    public private(set) var offsets: [UInt32]

    /// Token lengths in bytes (2 bytes each, max 65535).
    public private(set) var lengths: [UInt16]

    /// Line numbers (4 bytes each).
    public private(set) var lines: [UInt32]

    /// Column numbers (2 bytes each).
    public private(set) var columns: [UInt16]

    /// Number of tokens stored.
    public var count: Int { kinds.count }

    /// Whether the storage is empty.
    public var isEmpty: Bool { kinds.isEmpty }

    // MARK: - Memory Statistics

    /// Total memory used in bytes.
    public var memoryUsage: Int {
        kinds.count * MemoryLayout<UInt8>.size +
            offsets.count * MemoryLayout<UInt32>.size +
            lengths.count * MemoryLayout<UInt16>.size +
            lines.count * MemoryLayout<UInt32>.size +
            columns.count * MemoryLayout<UInt16>.size
    }

    /// Memory per token (average).
    public var bytesPerToken: Int {
        // 1 + 4 + 2 + 4 + 2 = 13 bytes per token
        13
    }

    // MARK: - Mutation

    /// Append a token.
    public mutating func append(
        kind: TokenKindByte,
        offset: UInt32,
        length: UInt16,
        line: UInt32,
        column: UInt16 = 0,
    ) {
        kinds.append(kind.rawValue)
        offsets.append(offset)
        lengths.append(length)
        lines.append(line)
        columns.append(column)
    }

    /// Append a token using Int parameters (convenience).
    public mutating func append(
        kind: TokenKindByte,
        offset: Int,
        length: Int,
        line: Int,
        column: Int = 0,
    ) {
        append(
            kind: kind,
            offset: UInt32(offset),
            length: UInt16(min(length, Int(UInt16.max))),
            line: UInt32(line),
            column: UInt16(min(column, Int(UInt16.max))),
        )
    }

    /// Reserve capacity for additional tokens.
    public mutating func reserveCapacity(_ capacity: Int) {
        kinds.reserveCapacity(capacity)
        offsets.reserveCapacity(capacity)
        lengths.reserveCapacity(capacity)
        lines.reserveCapacity(capacity)
        columns.reserveCapacity(capacity)
    }

    /// Clear all tokens.
    public mutating func removeAll(keepingCapacity: Bool = false) {
        kinds.removeAll(keepingCapacity: keepingCapacity)
        offsets.removeAll(keepingCapacity: keepingCapacity)
        lengths.removeAll(keepingCapacity: keepingCapacity)
        lines.removeAll(keepingCapacity: keepingCapacity)
        columns.removeAll(keepingCapacity: keepingCapacity)
    }

    // MARK: - Access

    /// Get kind at index.
    public func kind(at index: Int) -> TokenKindByte {
        TokenKindByte(rawValue: kinds[index])
    }

    /// Get offset at index.
    public func offset(at index: Int) -> Int {
        Int(offsets[index])
    }

    /// Get length at index.
    public func length(at index: Int) -> Int {
        Int(lengths[index])
    }

    /// Get line at index.
    public func line(at index: Int) -> Int {
        Int(lines[index])
    }

    /// Get column at index.
    public func column(at index: Int) -> Int {
        Int(columns[index])
    }

    /// Get token text from a memory-mapped file.
    public func text(at index: Int, from file: MemoryMappedFile) -> String? {
        let offset = offset(at: index)
        let length = length(at: index)
        return file.slice(offset: offset, length: length).asString()
    }

    // MARK: - Range Access

    /// Get a range of kinds.
    public func kindsRange(_ range: Range<Int>) -> ArraySlice<UInt8> {
        kinds[range]
    }

    /// Get a range of offsets.
    public func offsetsRange(_ range: Range<Int>) -> ArraySlice<UInt32> {
        offsets[range]
    }

    /// Get a range of lengths.
    public func lengthsRange(_ range: Range<Int>) -> ArraySlice<UInt16> {
        lengths[range]
    }

    /// Get a range of lines.
    public func linesRange(_ range: Range<Int>) -> ArraySlice<UInt32> {
        lines[range]
    }

    // MARK: - Iteration

    /// Iterate over all tokens.
    public func forEach(_ body: (Int, TokenKindByte, UInt32, UInt16, UInt32) -> Void) {
        for i in 0 ..< count {
            body(i, kind(at: i), offsets[i], lengths[i], lines[i])
        }
    }

    /// Iterate over token indices with a specific kind.
    public func indicesWithKind(_ kind: TokenKindByte) -> [Int] {
        var result: [Int] = []
        for i in 0 ..< count where kinds[i] == kind.rawValue {
            result.append(i)
        }
        return result
    }
}

// MARK: - ArenaTokenStorage

/// SoA token storage using arena allocation for zero-copy iteration.
///
/// This version uses raw memory buffers allocated from an arena,
/// providing even better cache performance and eliminating Swift
/// array overhead.
public struct ArenaTokenStorage: @unchecked Sendable {
    // MARK: Lifecycle

    /// Create from SoATokenStorage, allocating in the given arena.
    public init(from storage: SoATokenStorage, arena: Arena) {
        count = storage.count

        // Allocate and copy kinds
        let kindsBuffer = arena.allocate(count: count) as UnsafeMutableBufferPointer<UInt8>
        for (i, kind) in storage.kinds.enumerated() {
            kindsBuffer[i] = kind
        }
        kinds = UnsafeBufferPointer(kindsBuffer)

        // Allocate and copy offsets
        let offsetsBuffer = arena.allocate(count: count) as UnsafeMutableBufferPointer<UInt32>
        for (i, offset) in storage.offsets.enumerated() {
            offsetsBuffer[i] = offset
        }
        offsets = UnsafeBufferPointer(offsetsBuffer)

        // Allocate and copy lengths
        let lengthsBuffer = arena.allocate(count: count) as UnsafeMutableBufferPointer<UInt16>
        for (i, length) in storage.lengths.enumerated() {
            lengthsBuffer[i] = length
        }
        lengths = UnsafeBufferPointer(lengthsBuffer)

        // Allocate and copy lines
        let linesBuffer = arena.allocate(count: count) as UnsafeMutableBufferPointer<UInt32>
        for (i, line) in storage.lines.enumerated() {
            linesBuffer[i] = line
        }
        lines = UnsafeBufferPointer(linesBuffer)
    }

    // MARK: Public

    /// Token kinds buffer.
    public let kinds: UnsafeBufferPointer<UInt8>

    /// Byte offsets buffer.
    public let offsets: UnsafeBufferPointer<UInt32>

    /// Token lengths buffer.
    public let lengths: UnsafeBufferPointer<UInt16>

    /// Line numbers buffer.
    public let lines: UnsafeBufferPointer<UInt32>

    /// Number of tokens.
    public let count: Int

    /// Get kind at index.
    public func kind(at index: Int) -> TokenKindByte {
        TokenKindByte(rawValue: kinds[index])
    }

    /// Get offset at index.
    public func offset(at index: Int) -> Int {
        Int(offsets[index])
    }

    /// Get length at index.
    public func length(at index: Int) -> Int {
        Int(lengths[index])
    }

    /// Get line at index.
    public func line(at index: Int) -> Int {
        Int(lines[index])
    }
}

// MARK: - MultiFileSoAStorage

/// Concatenated token storage for multiple files with file boundaries.
///
/// This stores tokens from multiple files in a single contiguous storage,
/// with file boundary markers to separate files. Enables efficient
/// cross-file analysis without reallocating per file.
public struct MultiFileSoAStorage: Sendable {
    // MARK: Lifecycle

    public init() {
        storage = SoATokenStorage()
        files = []
    }

    // MARK: Public

    /// The underlying token storage.
    public private(set) var storage: SoATokenStorage

    /// File information: (path, startIndex, endIndex).
    public private(set) var files: [(path: String, start: Int, end: Int)]

    /// Total number of tokens across all files.
    public var totalTokenCount: Int {
        storage.count - files.count // Subtract boundary markers
    }

    /// Number of files.
    public var fileCount: Int {
        files.count
    }

    /// Add tokens for a new file.
    public mutating func addFile(path: String, tokens: SoATokenStorage) {
        let start = storage.count

        // Copy tokens
        for i in 0 ..< tokens.count {
            storage.append(
                kind: tokens.kind(at: i),
                offset: UInt32(tokens.offset(at: i)),
                length: UInt16(tokens.length(at: i)),
                line: UInt32(tokens.line(at: i)),
                column: UInt16(tokens.column(at: i)),
            )
        }

        let end = storage.count
        files.append((path, start, end))

        // Add file boundary marker (optional, for algorithms that need it)
        storage.append(
            kind: .fileBoundary,
            offset: 0,
            length: 0,
            line: 0,
        )
    }

    /// Get tokens for a specific file.
    public func tokens(forFile index: Int) -> (start: Int, end: Int) {
        let file = files[index]
        return (file.start, file.end)
    }

    /// Find which file a token index belongs to.
    public func fileIndex(forToken tokenIndex: Int) -> Int? {
        for (i, file) in files.enumerated() {
            if tokenIndex >= file.start, tokenIndex < file.end {
                return i
            }
        }
        return nil
    }
}

// MARK: - SIMD Operations on Token Arrays

public extension SoATokenStorage {
    /// Count tokens of each kind using SIMD acceleration.
    ///
    /// Returns an array where index corresponds to TokenKindByte.rawValue.
    func countByKind() -> [Int] {
        var counts = [Int](repeating: 0, count: 256)
        for kind in kinds {
            counts[Int(kind)] += 1
        }
        return counts
    }

    /// Find all tokens within a line range.
    func tokensInLineRange(_ lineRange: ClosedRange<Int>) -> Range<Int> {
        let startLine = UInt32(lineRange.lowerBound)
        let endLine = UInt32(lineRange.upperBound)

        var start: Int?
        var end = 0

        for i in 0 ..< count {
            let line = lines[i]
            if line >= startLine, line <= endLine {
                if start == nil { start = i }
                end = i + 1
            }
        }

        return (start ?? 0) ..< end
    }

    /// Hash a range of tokens for clone detection.
    ///
    /// Uses rolling hash combining kind and length.
    func hashRange(_ range: Range<Int>) -> UInt64 {
        var hash: UInt64 = 0
        let prime: UInt64 = 31

        for i in range {
            hash = hash &* prime &+ UInt64(kinds[i])
            hash = hash &* prime &+ UInt64(lengths[i])
        }

        return hash
    }

    /// Compare two ranges for equality (same kinds and lengths).
    func rangesEqual(_ range1: Range<Int>, _ range2: Range<Int>) -> Bool {
        guard range1.count == range2.count else { return false }

        for (i, j) in zip(range1, range2) {
            if kinds[i] != kinds[j] || lengths[i] != lengths[j] {
                return false
            }
        }

        return true
    }
}

// MARK: - Conversion Utilities

public extension SoATokenStorage {
    /// Create from an array of TokenInfo.
    static func from(_ tokens: [(kind: TokenKindByte, offset: Int, length: Int, line: Int, column: Int)])
        -> SoATokenStorage {
        var storage = SoATokenStorage(capacity: tokens.count)
        for token in tokens {
            storage.append(
                kind: token.kind,
                offset: token.offset,
                length: token.length,
                line: token.line,
                column: token.column,
            )
        }
        return storage
    }
}
