//
//  Arena.swift
//  SwiftStaticAnalysis
//
//  Arena allocator for region-based memory management.
//
//  Arena allocation provides extremely fast allocation through bump-pointer
//  semantics. Memory is allocated contiguously and all allocations are freed
//  at once when the arena is destroyed or reset.
//
//  Benefits:
//  - O(1) allocation (just increment a pointer)
//  - Cache-friendly contiguous memory layout
//  - No individual deallocation overhead
//  - Ideal for batch processing workloads
//

import Foundation

// MARK: - Arena Configuration

/// Configuration for arena allocation.
public struct ArenaConfiguration: Sendable {
    /// Default block size (64KB).
    public static let defaultBlockSize = 65536

    /// Block size for arena chunks.
    public let blockSize: Int

    /// Alignment for allocations.
    public let alignment: Int

    public init(blockSize: Int = defaultBlockSize, alignment: Int = 8) {
        self.blockSize = blockSize
        self.alignment = alignment
    }
}

// MARK: - Arena Block

/// A contiguous block of memory in the arena.
final class ArenaBlock: @unchecked Sendable {
    /// Raw memory storage.
    let storage: UnsafeMutableRawPointer

    /// Capacity of this block.
    let capacity: Int

    /// Current offset (bump pointer).
    var offset: Int

    init(capacity: Int) {
        self.storage = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: 8
        )
        self.capacity = capacity
        self.offset = 0
    }

    deinit {
        storage.deallocate()
    }

    /// Attempt to allocate memory in this block.
    ///
    /// - Parameters:
    ///   - size: Number of bytes to allocate.
    ///   - alignment: Alignment requirement.
    /// - Returns: Pointer to allocated memory, or nil if insufficient space.
    func allocate(size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
        // Align the current offset
        let alignedOffset = (offset + alignment - 1) & ~(alignment - 1)

        guard alignedOffset + size <= capacity else {
            return nil
        }

        let ptr = storage.advanced(by: alignedOffset)
        offset = alignedOffset + size
        return ptr
    }

    /// Reset the block for reuse.
    func reset() {
        offset = 0
    }
}

// MARK: - Arena

/// Region-based memory allocator with bump-pointer allocation.
///
/// Arena provides extremely fast allocation by simply incrementing a pointer.
/// Memory is freed all at once when the arena is destroyed or reset.
///
/// Thread Safety: Arena is NOT thread-safe. Use separate arenas per thread
/// or synchronize access externally.
///
/// Example:
/// ```swift
/// let arena = Arena()
/// let ptr = arena.allocate(size: 100, alignment: 8)
/// // Use memory...
/// arena.reset() // All allocations freed
/// ```
public final class Arena: @unchecked Sendable {
    /// Configuration for this arena.
    public let configuration: ArenaConfiguration

    /// Active memory blocks.
    private var blocks: [ArenaBlock] = []

    /// Current active block index.
    private var currentBlockIndex: Int = -1

    /// Statistics tracking.
    private var _totalAllocations: Int = 0
    private var _totalBytesAllocated: Int = 0
    private var _peakBytesAllocated: Int = 0

    public init(configuration: ArenaConfiguration = ArenaConfiguration()) {
        self.configuration = configuration
    }

    deinit {
        // Blocks are automatically deallocated via their deinitializers
    }

    // MARK: - Allocation

    /// Allocate raw memory from the arena.
    ///
    /// - Parameters:
    ///   - size: Number of bytes to allocate.
    ///   - alignment: Alignment requirement (default: 8).
    /// - Returns: Pointer to allocated memory.
    @discardableResult
    public func allocate(size: Int, alignment: Int = 8) -> UnsafeMutableRawPointer {
        // Try allocating from current block
        if currentBlockIndex >= 0 {
            if let ptr = blocks[currentBlockIndex].allocate(size: size, alignment: alignment) {
                updateStats(size: size)
                return ptr
            }
        }

        // Need a new block
        let blockSize = max(configuration.blockSize, size + alignment)
        let newBlock = ArenaBlock(capacity: blockSize)
        blocks.append(newBlock)
        currentBlockIndex = blocks.count - 1

        guard let ptr = newBlock.allocate(size: size, alignment: alignment) else {
            fatalError("Failed to allocate \(size) bytes in fresh arena block")
        }

        updateStats(size: size)
        return ptr
    }

    /// Allocate and initialize typed memory.
    ///
    /// - Parameter count: Number of elements to allocate.
    /// - Returns: Typed buffer pointer.
    public func allocate<T>(count: Int) -> UnsafeMutableBufferPointer<T> {
        let size = count * MemoryLayout<T>.stride
        let alignment = MemoryLayout<T>.alignment
        let raw = allocate(size: size, alignment: alignment)
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return UnsafeMutableBufferPointer(start: typed, count: count)
    }

    /// Allocate and store a single value.
    ///
    /// - Parameter value: Value to store.
    /// - Returns: Pointer to the stored value.
    @discardableResult
    public func store<T>(_ value: T) -> UnsafeMutablePointer<T> {
        let buffer = allocate(count: 1) as UnsafeMutableBufferPointer<T>
        buffer.baseAddress!.initialize(to: value)
        return buffer.baseAddress!
    }

    /// Allocate and copy an array.
    ///
    /// - Parameter array: Array to copy.
    /// - Returns: Buffer pointer to the copied array.
    public func copy<T>(_ array: [T]) -> UnsafeMutableBufferPointer<T> {
        let buffer = allocate(count: array.count) as UnsafeMutableBufferPointer<T>
        for (i, element) in array.enumerated() {
            buffer[i] = element
        }
        return buffer
    }

    // MARK: - Reset

    /// Reset the arena, freeing all allocations.
    ///
    /// This is O(n) where n is the number of blocks, but each block's
    /// memory is not individually freed - just the offset is reset.
    public func reset() {
        for block in blocks {
            block.reset()
        }
        currentBlockIndex = blocks.isEmpty ? -1 : 0
        _totalBytesAllocated = 0
    }

    /// Release all memory back to the system.
    ///
    /// Unlike reset(), this actually frees the underlying memory.
    public func release() {
        blocks.removeAll()
        currentBlockIndex = -1
        _totalBytesAllocated = 0
    }

    // MARK: - Statistics

    /// Total number of allocations made.
    public var totalAllocations: Int { _totalAllocations }

    /// Current bytes allocated.
    public var totalBytesAllocated: Int { _totalBytesAllocated }

    /// Peak bytes allocated.
    public var peakBytesAllocated: Int { _peakBytesAllocated }

    /// Number of memory blocks.
    public var blockCount: Int { blocks.count }

    /// Total capacity across all blocks.
    public var totalCapacity: Int {
        blocks.reduce(0) { $0 + $1.capacity }
    }

    /// Memory utilization percentage.
    public var utilization: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(_totalBytesAllocated) / Double(totalCapacity) * 100
    }

    private func updateStats(size: Int) {
        _totalAllocations += 1
        _totalBytesAllocated += size
        _peakBytesAllocated = max(_peakBytesAllocated, _totalBytesAllocated)
    }
}

// MARK: - Arena Allocator Protocol

/// Protocol for types that can be allocated in an arena.
public protocol ArenaAllocatable {
    /// Create an instance in the given arena.
    static func allocate(in arena: Arena, count: Int) -> UnsafeMutableBufferPointer<Self>
}

extension ArenaAllocatable {
    public static func allocate(in arena: Arena, count: Int) -> UnsafeMutableBufferPointer<Self> {
        arena.allocate(count: count)
    }
}

// Make common types arena-allocatable
extension Int: ArenaAllocatable {}
extension Int32: ArenaAllocatable {}
extension Int64: ArenaAllocatable {}
extension UInt: ArenaAllocatable {}
extension UInt32: ArenaAllocatable {}
extension UInt64: ArenaAllocatable {}
extension Float: ArenaAllocatable {}
extension Double: ArenaAllocatable {}
extension Bool: ArenaAllocatable {}

// MARK: - Scoped Arena

/// A scoped arena that automatically resets when the scope exits.
///
/// Example:
/// ```swift
/// let arena = Arena()
/// arena.withScope {
///     let data = $0.allocate(count: 1000) as UnsafeMutableBufferPointer<Int>
///     // Use data...
/// } // Arena automatically reset here
/// ```
extension Arena {
    /// Execute a closure with a scoped arena that resets after completion.
    ///
    /// - Parameter body: Closure that uses the arena.
    /// - Returns: The result of the closure.
    public func withScope<T>(_ body: (Arena) throws -> T) rethrows -> T {
        let startOffset = blocks.isEmpty ? 0 : blocks[max(0, currentBlockIndex)].offset
        let startBlock = currentBlockIndex

        defer {
            // Reset to the starting state
            if startBlock >= 0 && startBlock < blocks.count {
                for i in (startBlock + 1)..<blocks.count {
                    blocks[i].reset()
                }
                blocks[startBlock].offset = startOffset
                currentBlockIndex = startBlock
            } else {
                reset()
            }
        }

        return try body(self)
    }
}

// MARK: - Thread-Local Arena

/// Provides a thread-local arena for concurrent use.
public enum ThreadLocalArena {
    /// Thread-local storage for arenas.
    private static let tlsKey: pthread_key_t = {
        var key: pthread_key_t = 0
        pthread_key_create(&key) { ptr in
            // Destructor called when thread exits
            Unmanaged<Arena>.fromOpaque(ptr).release()
        }
        return key
    }()

    /// Get the arena for the current thread.
    public static var current: Arena {
        if let ptr = pthread_getspecific(tlsKey) {
            return Unmanaged<Arena>.fromOpaque(ptr).takeUnretainedValue()
        }

        let arena = Arena()
        pthread_setspecific(tlsKey, Unmanaged.passRetained(arena).toOpaque())
        return arena
    }

    /// Reset the current thread's arena.
    public static func reset() {
        current.reset()
    }
}
