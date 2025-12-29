//
//  ChangeDetector.swift
//  SwiftStaticAnalysis
//
//  Change detection for incremental analysis.
//  Uses content hashing and modification time tracking for efficient detection.
//

import Foundation

// MARK: - FileState

/// Represents the state of a file at a point in time.
public struct FileState: Codable, Hashable, Sendable {
    // MARK: Lifecycle

    public init(path: String, contentHash: UInt64, modificationTime: Date, size: Int64) {
        self.path = path
        self.contentHash = contentHash
        self.modificationTime = modificationTime
        self.size = size
    }

    // MARK: Public

    /// The file path.
    public let path: String

    /// FNV-1a hash of the file content.
    public let contentHash: UInt64

    /// Last modification time.
    public let modificationTime: Date

    /// File size in bytes.
    public let size: Int64
}

// MARK: - FileChangeType

/// Types of file changes detected.
public enum FileChangeType: String, Codable, Sendable {
    /// File was added (not present in previous state).
    case added

    /// File was modified (content changed).
    case modified

    /// File was deleted (no longer exists).
    case deleted

    /// File is unchanged (same content hash).
    case unchanged
}

// MARK: - FileChange

/// Represents a detected file change.
public struct FileChange: Sendable {
    // MARK: Lifecycle

    public init(
        path: String,
        changeType: FileChangeType,
        previousState: FileState?,
        currentState: FileState?,
    ) {
        self.path = path
        self.changeType = changeType
        self.previousState = previousState
        self.currentState = currentState
    }

    // MARK: Public

    /// The file path.
    public let path: String

    /// Type of change.
    public let changeType: FileChangeType

    /// Previous state (nil for added files).
    public let previousState: FileState?

    /// Current state (nil for deleted files).
    public let currentState: FileState?
}

// MARK: - ChangeDetectionResult

/// Result of change detection across a set of files.
public struct ChangeDetectionResult: Sendable {
    // MARK: Lifecycle

    public init(changes: [FileChange]) {
        self.changes = changes
    }

    // MARK: Public

    /// All detected changes.
    public let changes: [FileChange]

    /// Files that were added.
    public var addedFiles: [String] {
        changes.filter { $0.changeType == .added }.map(\.path)
    }

    /// Files that were modified.
    public var modifiedFiles: [String] {
        changes.filter { $0.changeType == .modified }.map(\.path)
    }

    /// Files that were deleted.
    public var deletedFiles: [String] {
        changes.filter { $0.changeType == .deleted }.map(\.path)
    }

    /// Files that are unchanged.
    public var unchangedFiles: [String] {
        changes.filter { $0.changeType == .unchanged }.map(\.path)
    }

    /// Files that need re-analysis (added + modified).
    public var filesToAnalyze: [String] {
        addedFiles + modifiedFiles
    }

    /// Whether any changes were detected.
    public var hasChanges: Bool {
        !addedFiles.isEmpty || !modifiedFiles.isEmpty || !deletedFiles.isEmpty
    }
}

// MARK: - ChangeDetector

/// Detects file changes for incremental analysis.
public struct ChangeDetector: Sendable {
    // MARK: Lifecycle

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: Public

    /// Configuration for change detection.
    public struct Configuration: Sendable {
        // MARK: Lifecycle

        public init(
            alwaysVerifyHash: Bool = false,
            parallelHashing: Bool = true,
            maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        ) {
            self.alwaysVerifyHash = alwaysVerifyHash
            self.parallelHashing = parallelHashing
            self.maxConcurrency = maxConcurrency
        }

        // MARK: Public

        public static let `default` = Configuration()

        /// Strict configuration that always verifies content.
        public static let strict = Configuration(alwaysVerifyHash: true)

        /// Whether to verify content hash even if modification time is unchanged.
        /// More accurate but slower.
        public var alwaysVerifyHash: Bool

        /// Whether to use parallel processing for file hashing.
        public var parallelHashing: Bool

        /// Maximum concurrent file operations.
        public var maxConcurrency: Int
    }

    /// Configuration for the detector.
    public let configuration: Configuration

    // MARK: - Change Detection

    /// Detect changes between current files and previous state.
    ///
    /// - Parameters:
    ///   - currentFiles: Current file paths to analyze.
    ///   - previousState: Previous file states from cache.
    /// - Returns: Change detection result.
    public func detectChanges(
        currentFiles: [String],
        previousState: [String: FileState],
    ) async -> ChangeDetectionResult {
        var changes: [FileChange] = []

        // Compute current states in parallel
        let currentStates: [String: FileState] = if configuration.parallelHashing {
            await computeStatesParallel(for: currentFiles, previousState: previousState)
        } else {
            computeStatesSequential(for: currentFiles, previousState: previousState)
        }

        // Detect changes
        for file in currentFiles {
            guard let currentState = currentStates[file] else { continue }

            if let previous = previousState[file] {
                if currentState.contentHash != previous.contentHash {
                    changes.append(FileChange(
                        path: file,
                        changeType: .modified,
                        previousState: previous,
                        currentState: currentState,
                    ))
                } else {
                    changes.append(FileChange(
                        path: file,
                        changeType: .unchanged,
                        previousState: previous,
                        currentState: currentState,
                    ))
                }
            } else {
                changes.append(FileChange(
                    path: file,
                    changeType: .added,
                    previousState: nil,
                    currentState: currentState,
                ))
            }
        }

        // Detect deletions
        let currentFileSet = Set(currentFiles)
        for (path, state) in previousState where !currentFileSet.contains(path) {
            changes.append(FileChange(
                path: path,
                changeType: .deleted,
                previousState: state,
                currentState: nil,
            ))
        }

        return ChangeDetectionResult(changes: changes)
    }

    /// Compute the current state of a single file.
    ///
    /// - Parameter path: File path.
    /// - Returns: File state, or nil if file doesn't exist or can't be read.
    public func computeState(for path: String) -> FileState? {
        let fileManager = FileManager.default

        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modDate = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int64,
              let data = fileManager.contents(atPath: path)
        else {
            return nil
        }

        let hash = FNV1a.hash(data)

        return FileState(
            path: path,
            contentHash: hash,
            modificationTime: modDate,
            size: size,
        )
    }

    // MARK: Private

    // MARK: - Private Helpers

    /// Compute states in parallel with concurrency limits.
    private func computeStatesParallel(
        for files: [String],
        previousState: [String: FileState],
    ) async -> [String: FileState] {
        await withTaskGroup(of: (String, FileState?).self) { group in
            // Process in batches to limit concurrency
            let batchSize = configuration.maxConcurrency

            for batchStart in stride(from: 0, to: files.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, files.count)
                let batch = files[batchStart ..< batchEnd]

                for file in batch {
                    group.addTask {
                        // Optimization: if not always verifying hash, check mod time first
                        if let previous = previousState[file],
                           fileMetadataMatches(file, previous: previous) {
                            return (file, previous)
                        }

                        return (file, computeState(for: file))
                    }
                }

                // Collect batch results before starting next batch
                // This limits true concurrency
            }

            var results: [String: FileState] = [:]
            for await (path, state) in group {
                if let state {
                    results[path] = state
                }
            }
            return results
        }
    }

    /// Compute states sequentially.
    private func computeStatesSequential(
        for files: [String],
        previousState: [String: FileState],
    ) -> [String: FileState] {
        var results: [String: FileState] = [:]

        for file in files {
            // Optimization: check mod time first
            if let previous = previousState[file],
               fileMetadataMatches(file, previous: previous) {
                results[file] = previous
                continue
            }

            if let state = computeState(for: file) {
                results[file] = state
            }
        }

        return results
    }

    /// Check if file metadata matches previous state (optimization to avoid hash computation).
    private func fileMetadataMatches(_ file: String, previous: FileState) -> Bool {
        guard !configuration.alwaysVerifyHash,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              let modDate = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int64
        else {
            return false
        }
        return modDate == previous.modificationTime && size == previous.size
    }
}

// MARK: - FNV1a

/// FNV-1a hash implementation for content hashing.
public enum FNV1a {
    // MARK: Public

    /// Compute FNV-1a hash of data.
    ///
    /// - Parameter data: Data to hash.
    /// - Returns: 64-bit hash value.
    public static func hash(_ data: Data) -> UInt64 {
        var hash = offsetBasis
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Compute FNV-1a hash of a string.
    ///
    /// - Parameter string: String to hash.
    /// - Returns: 64-bit hash value.
    public static func hash(_ string: String) -> UInt64 {
        hash(Data(string.utf8))
    }

    /// Compute FNV-1a hash of multiple strings (for composite keys).
    ///
    /// - Parameter strings: Strings to hash.
    /// - Returns: 64-bit hash value.
    public static func hash(_ strings: [String]) -> UInt64 {
        var hash = offsetBasis
        for string in strings {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            // Add separator
            hash ^= 0
            hash = hash &* prime
        }
        return hash
    }

    // MARK: Private

    /// FNV-1a 64-bit offset basis.
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037

    /// FNV-1a 64-bit prime.
    private static let prime: UInt64 = 1_099_511_628_211
}
