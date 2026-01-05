//  RegexCache.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

// MARK: - RegexCache

/// Thread-safe cache for compiled regex patterns.
///
/// Use this cache to avoid repeated compilation of the same regex patterns.
/// Patterns are compiled lazily on first access and cached for subsequent use.
///
/// ```swift
/// let cache = RegexCache()
/// if let regex = cache.regex(for: "foo.*bar") {
///     if text.contains(regex) { ... }
/// }
/// ```
///
/// - Note: This class is safe to use from multiple threads/tasks.
public final class RegexCache: @unchecked Sendable {
    // MARK: Lifecycle

    /// Creates a new regex cache.
    ///
    /// - Parameter capacity: Maximum number of patterns to cache. Defaults to 100.
    public init(capacity: Int = 100) {
        self.capacity = capacity
    }

    // MARK: Public

    /// Shared cache instance for common patterns.
    public static let shared = RegexCache()

    /// Gets or compiles a regex for the given pattern.
    ///
    /// - Parameter pattern: The regex pattern string.
    /// - Returns: The compiled regex, or nil if the pattern is invalid.
    public func regex(for pattern: String) -> Regex<AnyRegexOutput>? {
        lock.lock()
        defer { lock.unlock() }

        // Check cache first
        if let cached = cache[pattern] {
            return cached
        }

        // Compile and cache
        guard let compiled = try? Regex(pattern) else {
            return nil
        }

        // Evict oldest entry if at capacity
        if cache.count >= capacity {
            // Simple eviction: remove first entry
            if let firstKey = cache.keys.first {
                cache.removeValue(forKey: firstKey)
            }
        }

        cache[pattern] = compiled
        return compiled
    }

    /// Checks if a pattern is already cached.
    ///
    /// - Parameter pattern: The regex pattern string.
    /// - Returns: True if the pattern is cached.
    public func isCached(_ pattern: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[pattern] != nil
    }

    /// Clears all cached patterns.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    /// Number of patterns currently cached.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    // MARK: Private

    private let capacity: Int
    private var cache: [String: Regex<AnyRegexOutput>] = [:]
    private let lock = NSLock()
}

// MARK: - CompiledPatterns

/// Pre-compiled collection of regex patterns.
///
/// Use this to compile a set of patterns once at initialization time,
/// avoiding repeated compilation during matching.
///
/// ```swift
/// let patterns = CompiledPatterns(["test.*", "mock.*", "stub.*"])
/// if patterns.anyMatches("testFile.swift") { ... }
/// ```
///
/// - Note: Safe to use concurrently because patterns are immutable after initialization.
public struct CompiledPatterns: @unchecked Sendable, Sequence {
    // MARK: Lifecycle

    /// Creates compiled patterns from string patterns.
    ///
    /// Invalid patterns are silently ignored.
    ///
    /// - Parameter patterns: Array of regex pattern strings.
    public init(_ patterns: [String]) {
        compiled = patterns.compactMap { pattern in
            try? Regex(pattern)
        }
    }

    // MARK: Public

    /// Whether any of the patterns match the given string.
    ///
    /// - Parameter string: The string to check.
    /// - Returns: True if any pattern matches.
    public func anyMatches(_ string: String) -> Bool {
        compiled.contains { string.contains($0) }
    }

    /// Number of successfully compiled patterns.
    public var count: Int { compiled.count }

    /// Whether there are no patterns.
    public var isEmpty: Bool { compiled.isEmpty }

    public func makeIterator() -> IndexingIterator<[Regex<AnyRegexOutput>]> {
        compiled.makeIterator()
    }

    // MARK: Private

    /// The compiled regex patterns (immutable after init).
    private let compiled: [Regex<AnyRegexOutput>]
}
