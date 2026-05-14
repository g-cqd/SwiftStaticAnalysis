//  Bitmap.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Synchronization

// MARK: - AtomicWord

/// Heap-allocated wrapper around a single `Atomic<UInt64>`.
///
/// `Atomic` is `~Copyable`, so it can't sit directly in an Array. Wrapping it
/// in a small reference type gives the storage equivalent of swift-atomics'
/// `ManagedAtomic<UInt64>` while keeping the codebase on the stdlib
/// `Synchronization` module.
private final class AtomicWord: Sendable {
    let value: Atomic<UInt64>

    init(_ initial: UInt64 = 0) {
        self.value = Atomic<UInt64>(initial)
    }
}

// MARK: - AtomicBitmap

/// Thread-safe bitmap for parallel BFS visited tracking.
///
/// Uses stdlib `Atomic<UInt64>` (via `AtomicWord`) for lock-free concurrent
/// access. The `@unchecked Sendable` annotation reflects that the array of
/// reference-typed `AtomicWord`s is read-only after init while the atomic
/// fields are themselves `Sendable`.
///
/// ## Performance Characteristics
///
/// - `testAndSet`: O(1) with atomic fetch-or
/// - `test`: O(1) atomic load
/// - `popCount`: O(n/64) where n is bitmap size
/// - Memory: ~n/8 bytes for n bits plus per-word reference overhead
public final class AtomicBitmap: @unchecked Sendable {
    // MARK: Lifecycle

    /// Create a bitmap with the given number of bits, all initially unset.
    public init(size: Int) {
        precondition(size >= 0, "Bitmap size must be non-negative")
        self.size = size
        self.wordCount = (size + 63) / 64
        self.storage = (0..<wordCount).map { _ in AtomicWord() }
    }

    // MARK: Public

    /// Number of bits in the bitmap.
    public let size: Int

    /// Atomically test and set a bit.
    ///
    /// - Parameter index: The bit index to set.
    /// - Returns: `true` if the bit was previously unset (and is now set),
    ///            `false` if it was already set.
    ///
    /// This operation is atomic and thread-safe using fetch-or.
    @inline(__always)
    public func testAndSet(_ index: Int) -> Bool {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        // Atomic fetch-or: sets the bit and returns the OLD value
        let (oldValue, _) = storage[wordIndex].value.bitwiseOr(mask, ordering: .relaxed)

        // Return true if the bit was previously unset
        return (oldValue & mask) == 0
    }

    /// Set a bit without atomicity guarantee (for single-threaded initialization).
    ///
    /// Note: This still uses atomic store for consistency but doesn't need
    /// the fetch-or pattern. For batch initialization, this is marginally faster.
    @inline(__always)
    public func set(_ index: Int) {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        _ = storage[wordIndex].value.bitwiseOr(mask, ordering: .relaxed)
    }

    /// Check if a bit is set (atomic read).
    ///
    /// - Parameter index: The bit index to check.
    /// - Returns: `true` if the bit is set, `false` otherwise.
    @inline(__always)
    public func test(_ index: Int) -> Bool {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        return (storage[wordIndex].value.load(ordering: .relaxed) & mask) != 0
    }

    /// Count of set bits (population count).
    ///
    /// Provides a per-word relaxed-ordering snapshot. Concurrent writers
    /// between words are not coordinated; the result is consistent only
    /// within each word.
    public var popCount: Int {
        var count = 0
        for i in 0..<wordCount {
            count += storage[i].value.load(ordering: .relaxed).nonzeroBitCount
        }
        return count
    }

    /// Iterate over all set bit indices.
    ///
    /// - Parameter body: Closure called for each set bit index.
    public func forEachSetBit(_ body: (Int) -> Void) {
        for wordIndex in 0..<wordCount {
            var word = storage[wordIndex].value.load(ordering: .relaxed)
            let baseIndex = wordIndex * 64

            while word != 0 {
                let bitIndex = word.trailingZeroBitCount
                let globalIndex = baseIndex + bitIndex
                if globalIndex < size {
                    body(globalIndex)
                }
                word &= word - 1  // Clear lowest set bit
            }
        }
    }

    /// Get all set bit indices as an array.
    public func allSetBits() -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(min(popCount, size))
        forEachSetBit { result.append($0) }
        return result
    }

    /// Clear all bits.
    public func clear() {
        for i in 0..<wordCount {
            storage[i].value.store(0, ordering: .relaxed)
        }
    }

    /// Copy contents from another bitmap.
    public func copy(from other: AtomicBitmap) {
        precondition(size == other.size, "Bitmap sizes must match for copy")
        for i in 0..<wordCount {
            let value = other.storage[i].value.load(ordering: .relaxed)
            storage[i].value.store(value, ordering: .relaxed)
        }
    }

    // MARK: Private

    private let storage: [AtomicWord]
    private let wordCount: Int
}

// MARK: - Bitmap (Non-Atomic)

/// Non-atomic bitmap for single-threaded use.
///
/// More efficient than `AtomicBitmap` when thread safety is not required.
public struct Bitmap: Sendable {
    // MARK: Lifecycle

    /// Create a bitmap with the given number of bits, all initially unset.
    public init(size: Int) {
        precondition(size >= 0, "Bitmap size must be non-negative")
        self.size = size
        let wordCount = (size + 63) / 64
        self.storage = [UInt64](repeating: 0, count: wordCount)
    }

    /// Create a bitmap with the given number of bits, setting specified indices.
    ///
    /// This is more efficient than creating an empty bitmap and calling `set`
    /// repeatedly because it initializes all bits in a single pass and avoids
    /// the need for a mutable variable (important for Sendable conformance
    /// when captured by closures).
    public init(size: Int, setting indices: some Sequence<Int>) {
        precondition(size >= 0, "Bitmap size must be non-negative")
        self.size = size
        let wordCount = (size + 63) / 64
        var storage = [UInt64](repeating: 0, count: wordCount)

        for index in indices {
            precondition(index >= 0 && index < size, "Bitmap index out of bounds")
            let wordIndex = index / 64
            let bitIndex = index % 64
            let mask: UInt64 = 1 << bitIndex
            storage[wordIndex] |= mask
        }

        self.storage = storage
    }

    // MARK: Public

    /// Number of bits in the bitmap.
    public let size: Int

    /// Set a bit.
    @inline(__always)
    public mutating func set(_ index: Int) {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        storage[wordIndex] |= mask
    }

    /// Clear a bit.
    @inline(__always)
    public mutating func clear(_ index: Int) {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        storage[wordIndex] &= ~mask
    }

    /// Check if a bit is set.
    @inline(__always)
    public func test(_ index: Int) -> Bool {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        return (storage[wordIndex] & mask) != 0
    }

    /// Test and set a bit. Returns true if bit was previously unset.
    @inline(__always)
    public mutating func testAndSet(_ index: Int) -> Bool {
        let wasSet = test(index)
        if !wasSet {
            set(index)
        }
        return !wasSet
    }

    /// Count of set bits.
    public var popCount: Int {
        storage.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// Iterate over all set bit indices.
    public func forEachSetBit(_ body: (Int) -> Void) {
        for (wordIndex, var word) in storage.enumerated() {
            let baseIndex = wordIndex * 64

            while word != 0 {
                let bitIndex = word.trailingZeroBitCount
                let globalIndex = baseIndex + bitIndex
                if globalIndex < size {
                    body(globalIndex)
                }
                word &= word - 1
            }
        }
    }

    /// Get all set bit indices as an array.
    public func allSetBits() -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(popCount)
        forEachSetBit { result.append($0) }
        return result
    }

    /// Clear all bits.
    public mutating func clearAll() {
        for i in 0..<storage.count {
            storage[i] = 0
        }
    }

    // MARK: Private

    private var storage: [UInt64]
}
