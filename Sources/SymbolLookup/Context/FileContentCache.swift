//  FileContentCache.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation

/// An actor that caches file contents with LRU eviction.
///
/// This cache reduces file I/O when extracting context for multiple symbols
/// in the same file or when repeatedly accessing the same files.
///
/// ## Thread Safety
///
/// As an `actor`, all access is automatically serialized, making it safe
/// to use from multiple concurrent tasks.
///
/// ## Memory Management
///
/// The cache uses LRU eviction when it reaches capacity. Old entries are
/// automatically removed to make room for new ones.
///
/// ## Usage
///
/// ```swift
/// let cache = FileContentCache(maxEntries: 100)
/// let content = try await cache.content(for: "/path/to/file.swift")
/// ```
public actor FileContentCache {
    /// Maximum number of entries in the cache.
    private let maxEntries: Int

    /// Cached file contents keyed by path.
    private var cache: [String: CacheEntry] = [:]

    /// Order of access for LRU eviction (most recent at end).
    private var accessOrder: [String] = []

    /// Cache entry with content and metadata.
    private struct CacheEntry {
        let content: String
        let modificationDate: Date?
    }

    /// Creates a new file content cache.
    ///
    /// - Parameter maxEntries: Maximum number of files to cache. Defaults to 50.
    public init(maxEntries: Int = 50) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Gets the content of a file, using cached content if available and valid.
    ///
    /// - Parameter path: The file path to read.
    /// - Returns: The file content.
    /// - Throws: If the file cannot be read.
    public func content(for path: String) throws -> String {
        // Check if we have a valid cached entry
        if let entry = cache[path] {
            // Verify the file hasn't been modified
            if isEntryValid(entry, for: path) {
                // Move to end of access order (most recently used)
                updateAccessOrder(path)
                return entry.content
            }
            // Entry is stale, remove it
            cache.removeValue(forKey: path)
            accessOrder.removeAll { $0 == path }
        }

        // Read file and cache it
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let modDate = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date

        // Evict if at capacity
        while cache.count >= maxEntries {
            evictOldest()
        }

        cache[path] = CacheEntry(content: content, modificationDate: modDate)
        accessOrder.append(path)

        return content
    }

    /// Invalidates a cached entry.
    ///
    /// - Parameter path: The file path to invalidate.
    public func invalidate(_ path: String) {
        cache.removeValue(forKey: path)
        accessOrder.removeAll { $0 == path }
    }

    /// Invalidates all entries matching a pattern.
    ///
    /// - Parameter pattern: A predicate that returns true for paths to invalidate.
    public func invalidate(where pattern: (String) -> Bool) {
        let toRemove = cache.keys.filter(pattern)
        for path in toRemove {
            cache.removeValue(forKey: path)
            accessOrder.removeAll { $0 == path }
        }
    }

    /// Clears all cached entries.
    public func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// The number of cached entries.
    public var count: Int {
        cache.count
    }

    /// Whether a path is currently cached.
    public func isCached(_ path: String) -> Bool {
        cache[path] != nil
    }

    /// Preloads content for multiple files.
    ///
    /// This is useful when you know you'll need multiple files and want
    /// to load them efficiently.
    ///
    /// - Parameter paths: The file paths to preload.
    /// - Throws: If any file cannot be read.
    public func preload(_ paths: [String]) throws {
        for path in paths {
            _ = try content(for: path)
        }
    }

    // MARK: - Private

    /// Checks if a cache entry is still valid.
    private func isEntryValid(_ entry: CacheEntry, for path: String) -> Bool {
        guard let cachedDate = entry.modificationDate else {
            // No modification date recorded, assume valid
            return true
        }

        guard let currentDate = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        else {
            // Can't get current date, assume valid
            return true
        }

        return cachedDate >= currentDate
    }

    /// Updates the access order for a path (moves to end).
    private func updateAccessOrder(_ path: String) {
        accessOrder.removeAll { $0 == path }
        accessOrder.append(path)
    }

    /// Evicts the oldest entry.
    private func evictOldest() {
        guard let oldest = accessOrder.first else { return }
        cache.removeValue(forKey: oldest)
        accessOrder.removeFirst()
    }
}

// MARK: - Convenience Extensions

extension FileContentCache {
    /// Gets the content of a file as an array of lines.
    ///
    /// - Parameter path: The file path to read.
    /// - Returns: The file content split into lines.
    /// - Throws: If the file cannot be read.
    public func lines(for path: String) throws -> [String] {
        try content(for: path).components(separatedBy: "\n")
    }

    /// Gets the content of a specific line range.
    ///
    /// - Parameters:
    ///   - path: The file path.
    ///   - range: The range of line numbers (1-indexed).
    /// - Returns: The lines in the specified range.
    /// - Throws: If the file cannot be read.
    public func lines(for path: String, in range: ClosedRange<Int>) throws -> [String] {
        let allLines = try lines(for: path)
        let startIndex = max(0, range.lowerBound - 1)
        let endIndex = min(allLines.count, range.upperBound)

        guard startIndex < endIndex else { return [] }
        return Array(allLines[startIndex..<endIndex])
    }
}
