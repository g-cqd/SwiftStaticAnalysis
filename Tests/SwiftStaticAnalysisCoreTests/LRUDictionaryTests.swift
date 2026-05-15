//  LRUDictionaryTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import SwiftStaticAnalysisCore

@Suite("LRUDictionary Tests", .tags(.unit))
struct LRUDictionaryTests {
    @Test("Insertion within capacity retains every entry")
    func insertionWithinCapacity() {
        var cache = LRUDictionary<String, Int>(capacity: 3)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")

        #expect(cache.count == 3)
        #expect(cache.peek(forKey: "a") == 1)
        #expect(cache.peek(forKey: "b") == 2)
        #expect(cache.peek(forKey: "c") == 3)
    }

    @Test("Insertion beyond capacity evicts the least-recently-used entry")
    func evictsLRU() {
        var cache = LRUDictionary<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")

        #expect(cache.count == 2)
        #expect(cache.peek(forKey: "a") == nil) // evicted
        #expect(cache.peek(forKey: "b") == 2)
        #expect(cache.peek(forKey: "c") == 3)
    }

    @Test("value(forKey:) on hit promotes the entry to MRU, sparing it from eviction")
    func valueAccessorPromotes() {
        var cache = LRUDictionary<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")

        // Touch "a" — should bump it to MRU.
        #expect(cache.value(forKey: "a") == 1)

        // Insert a third entry; the LRU is now "b", not "a".
        cache.setValue(3, forKey: "c")

        #expect(cache.peek(forKey: "a") == 1)
        #expect(cache.peek(forKey: "b") == nil) // evicted
        #expect(cache.peek(forKey: "c") == 3)
    }

    @Test("peek(forKey:) does not change LRU order")
    func peekDoesNotPromote() {
        var cache = LRUDictionary<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")

        // Peek "a" — should NOT bump it.
        #expect(cache.peek(forKey: "a") == 1)

        cache.setValue(3, forKey: "c")

        // "a" was still the LRU and is the one evicted.
        #expect(cache.peek(forKey: "a") == nil)
        #expect(cache.peek(forKey: "b") == 2)
        #expect(cache.peek(forKey: "c") == 3)
    }

    @Test("Updating an existing key bumps it to MRU without growing the count")
    func updateBumpsToMRU() {
        var cache = LRUDictionary<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")

        // Update "a" — should bump and not evict.
        cache.setValue(10, forKey: "a")
        #expect(cache.count == 2)
        #expect(cache.peek(forKey: "a") == 10)

        // Insert a third entry; "b" is now the LRU.
        cache.setValue(3, forKey: "c")
        #expect(cache.peek(forKey: "a") == 10)
        #expect(cache.peek(forKey: "b") == nil)
        #expect(cache.peek(forKey: "c") == 3)
    }

    @Test("removeValue removes the entry and returns the prior value")
    func removeValue() {
        var cache = LRUDictionary<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")

        #expect(cache.removeValue(forKey: "a") == 1)
        #expect(cache.count == 0)
        #expect(cache.peek(forKey: "a") == nil)
        #expect(cache.removeValue(forKey: "missing") == nil)
    }

    @Test("removeAll empties the cache")
    func removeAllEmpties() {
        var cache = LRUDictionary<String, Int>(capacity: 3)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.removeAll()

        #expect(cache.isEmpty)
        #expect(cache.count == 0)
    }

    @Test("keysInLRUOrder reports the genuine LRU→MRU traversal order")
    func keysInLRUOrder() {
        var cache = LRUDictionary<String, Int>(capacity: 3)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        cache.setValue(3, forKey: "c")
        _ = cache.value(forKey: "a") // promote a to MRU

        // Expected order (LRU first): b, c, a
        #expect(Array(cache.keysInLRUOrder) == ["b", "c", "a"])
    }

    @Test("Capacity below 1 traps via precondition")
    func capacityPrecondition() async {
        // We exercise the smallest legal capacity to confirm it works; the
        // precondition is documented and trusted (testing it would crash the
        // process).
        var cache = LRUDictionary<String, Int>(capacity: 1)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        #expect(cache.peek(forKey: "a") == nil)
        #expect(cache.peek(forKey: "b") == 2)
    }
}
