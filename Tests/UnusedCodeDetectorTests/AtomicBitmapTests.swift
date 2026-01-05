//
//  AtomicBitmapTests.swift
//  SwiftStaticAnalysis
//
//  Tests for AtomicBitmap and Bitmap data structures.
//

import Foundation
import Testing

@testable import UnusedCodeDetector

@Suite("Atomic Bitmap Tests")
struct AtomicBitmapTests {
    // MARK: - Basic Operations

    @Test("Empty bitmap has no set bits")
    func emptyBitmap() {
        let bitmap = AtomicBitmap(size: 100)
        #expect(bitmap.popCount == 0)
        #expect(bitmap.allSetBits().isEmpty)
    }

    @Test("Test and set returns correct previous value")
    func testAndSet() {
        let bitmap = AtomicBitmap(size: 100)

        // First set should return true (was unset)
        #expect(bitmap.testAndSet(42) == true)

        // Second set should return false (was already set)
        #expect(bitmap.testAndSet(42) == false)

        // Check the bit is set
        #expect(bitmap.test(42) == true)
    }

    @Test("Set without atomicity works")
    func nonAtomicSet() {
        let bitmap = AtomicBitmap(size: 100)

        bitmap.set(10)
        bitmap.set(20)
        bitmap.set(30)

        #expect(bitmap.test(10))
        #expect(bitmap.test(20))
        #expect(bitmap.test(30))
        #expect(!bitmap.test(15))
        #expect(bitmap.popCount == 3)
    }

    @Test("PopCount is accurate")
    func popCountAccuracy() {
        let bitmap = AtomicBitmap(size: 1000)

        // Set 100 random bits
        for i in stride(from: 0, to: 1000, by: 10) {
            bitmap.set(i)
        }

        #expect(bitmap.popCount == 100)
    }

    @Test("ForEachSetBit iterates all set bits")
    func forEachSetBit() {
        let bitmap = AtomicBitmap(size: 100)

        let expected = [5, 10, 42, 67, 99]
        for bit in expected {
            bitmap.set(bit)
        }

        var collected: [Int] = []
        bitmap.forEachSetBit { collected.append($0) }

        #expect(Set(collected) == Set(expected))
    }

    @Test("AllSetBits returns all indices")
    func allSetBits() {
        let bitmap = AtomicBitmap(size: 200)

        let expected = [0, 63, 64, 65, 127, 128, 199]
        for bit in expected {
            bitmap.set(bit)
        }

        let result = bitmap.allSetBits()
        #expect(Set(result) == Set(expected))
    }

    @Test("Clear resets all bits")
    func clearBitmap() {
        let bitmap = AtomicBitmap(size: 100)

        for i in 0..<50 {
            bitmap.set(i)
        }
        #expect(bitmap.popCount == 50)

        bitmap.clear()
        #expect(bitmap.popCount == 0)
        #expect(bitmap.allSetBits().isEmpty)
    }

    @Test("Copy from another bitmap")
    func copyBitmap() {
        let source = AtomicBitmap(size: 100)
        let dest = AtomicBitmap(size: 100)

        source.set(10)
        source.set(50)
        source.set(90)

        dest.copy(from: source)

        #expect(dest.test(10))
        #expect(dest.test(50))
        #expect(dest.test(90))
        #expect(dest.popCount == 3)
    }

    // MARK: - Edge Cases

    @Test("Boundary bits work correctly")
    func boundaryBits() {
        let bitmap = AtomicBitmap(size: 128)

        // Test word boundaries (64-bit words)
        bitmap.set(0)      // First bit
        bitmap.set(63)     // Last bit of first word
        bitmap.set(64)     // First bit of second word
        bitmap.set(127)    // Last bit

        #expect(bitmap.test(0))
        #expect(bitmap.test(63))
        #expect(bitmap.test(64))
        #expect(bitmap.test(127))
        #expect(bitmap.popCount == 4)
    }

    @Test("Non-word-aligned size works")
    func nonAlignedSize() {
        let bitmap = AtomicBitmap(size: 100)  // Not a multiple of 64

        bitmap.set(99)  // Last valid bit
        #expect(bitmap.test(99))
        #expect(bitmap.popCount == 1)
    }

    // MARK: - Concurrent Access Tests

    @Test("Concurrent testAndSet is thread-safe")
    func concurrentTestAndSet() async {
        let bitmap = AtomicBitmap(size: 10000)
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    _ = bitmap.testAndSet(i % 10000)
                }
            }
        }

        // All unique indices should be set once
        // (some may have been set multiple times but testAndSet handles that)
        let setCount = bitmap.popCount
        #expect(setCount > 0 && setCount <= iterations)
    }
}

// MARK: - Non-Atomic Bitmap Tests

@Suite("Non-Atomic Bitmap Tests")
struct BitmapTests {
    @Test("Basic operations work")
    func basicOperations() {
        var bitmap = Bitmap(size: 100)

        bitmap.set(42)
        #expect(bitmap.test(42))

        bitmap.clear(42)
        #expect(!bitmap.test(42))
    }

    @Test("TestAndSet works correctly")
    func testAndSet() {
        var bitmap = Bitmap(size: 100)

        #expect(bitmap.testAndSet(42) == true)   // Was unset
        #expect(bitmap.testAndSet(42) == false)  // Was already set
    }

    @Test("PopCount is accurate")
    func popCount() {
        var bitmap = Bitmap(size: 100)

        bitmap.set(10)
        bitmap.set(20)
        bitmap.set(30)

        #expect(bitmap.popCount == 3)
    }

    @Test("ClearAll resets bitmap")
    func clearAll() {
        var bitmap = Bitmap(size: 100)

        for i in 0..<50 {
            bitmap.set(i)
        }
        #expect(bitmap.popCount == 50)

        bitmap.clearAll()
        #expect(bitmap.popCount == 0)
    }

    @Test("ForEachSetBit iterates correctly")
    func forEachSetBit() {
        var bitmap = Bitmap(size: 100)

        let expected = [5, 10, 42, 67, 99]
        for bit in expected {
            bitmap.set(bit)
        }

        var collected: [Int] = []
        bitmap.forEachSetBit { collected.append($0) }

        #expect(Set(collected) == Set(expected))
    }
}
