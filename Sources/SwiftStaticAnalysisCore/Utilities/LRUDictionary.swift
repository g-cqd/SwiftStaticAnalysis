//  LRUDictionary.swift
//  SwiftStaticAnalysis
//  MIT License

import Collections

// MARK: - LRUDictionary

/// A bounded, value-type least-recently-used dictionary backed by
/// `OrderedDictionary` from swift-collections.
///
/// `LRUDictionary` is the single source of truth for LRU caching in this
/// package. It owns no synchronization — callers wrap it in an actor or a
/// `Synchronization.Mutex` as appropriate. Two access patterns are exposed:
///
/// - `value(forKey:)` returns the value **and promotes the entry** to most
///   recently used. Use this for the standard "read promotes to MRU" cache
///   shape.
/// - `peek(forKey:)` returns the value **without** changing the order. Use
///   this for status checks (e.g. `isCached`).
///
/// Insertion via `setValue(_:forKey:)` evicts the least-recently-used entry
/// when the dictionary is at capacity. Updating an existing key promotes that
/// entry to the MRU position.
///
/// The previous implementation used `Dictionary<Key, Value>.keys.first` to
/// pick an eviction victim, which has undefined iteration order — that bug
/// is fixed here because `OrderedDictionary` preserves insertion order and
/// `removeFirst()` always evicts the genuine least-recently-used entry.
public struct LRUDictionary<Key: Hashable, Value> {
    // MARK: Lifecycle

    /// Create a new LRU dictionary with the given maximum capacity.
    ///
    /// - Precondition: `capacity >= 1`.
    public init(capacity: Int) {
        precondition(capacity >= 1, "LRUDictionary capacity must be >= 1")
        self.capacity = capacity
        self.storage = [:]
    }

    // MARK: Public

    /// Maximum number of entries retained before eviction begins.
    public let capacity: Int

    /// Current number of entries.
    public var count: Int { storage.count }

    /// Whether the dictionary is empty.
    public var isEmpty: Bool { storage.isEmpty }

    /// Look up the value for `key` and promote the entry to most-recently-used
    /// on hit. Returns `nil` when the key is not present.
    public mutating func value(forKey key: Key) -> Value? {
        guard let existing = storage.removeValue(forKey: key) else { return nil }
        storage[key] = existing
        return existing
    }

    /// Look up the value for `key` without changing the LRU order.
    public func peek(forKey key: Key) -> Value? {
        storage[key]
    }

    /// Insert or update an entry. The entry becomes most-recently-used. When
    /// adding a new entry beyond capacity, the least-recently-used entry is
    /// evicted first.
    public mutating func setValue(_ value: Value, forKey key: Key) {
        if storage[key] != nil {
            // Updating: drop then re-insert so the entry moves to MRU.
            storage.removeValue(forKey: key)
        } else if storage.count >= capacity {
            storage.removeFirst()
        }
        storage[key] = value
    }

    /// Remove and return the value for `key`, or `nil` if not present.
    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        storage.removeValue(forKey: key)
    }

    /// Remove every entry.
    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
    }

    /// The keys in least-recently-used to most-recently-used order. Useful
    /// for diagnostics and tests; not intended as a hot path.
    public var keysInLRUOrder: OrderedSet<Key> {
        OrderedSet(storage.keys)
    }

    // MARK: Private

    private var storage: OrderedDictionary<Key, Value>
}

extension LRUDictionary: Sendable where Key: Sendable, Value: Sendable {}
