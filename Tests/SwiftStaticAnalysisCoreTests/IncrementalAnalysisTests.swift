//  IncrementalAnalysisTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore

// MARK: - ChangeDetectorTests

@Suite("Change Detector Tests")
struct ChangeDetectorTests {
    @Test("Finds no changes for same files")
    func changeDetectorFindsNoChangesForSameFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a test file
        let testFile = tempDir.appendingPathComponent("Test.swift")
        try "let x = 1".write(to: testFile, atomically: true, encoding: .utf8)

        let detector = ChangeDetector()

        // First detection - all files are new
        let firstState = await detector.detectChanges(
            currentFiles: [testFile.path],
            previousState: [:],
        )

        #expect(firstState.addedFiles.count == 1)
        #expect(firstState.modifiedFiles.isEmpty)
        #expect(firstState.unchangedFiles.isEmpty)

        // Build previous state from first detection
        var previousState: [String: FileState] = [:]
        for change in firstState.changes {
            if let state = change.currentState {
                previousState[change.path] = state
            }
        }

        // Second detection with same state - no changes
        let secondResult = await detector.detectChanges(
            currentFiles: [testFile.path],
            previousState: previousState,
        )

        #expect(secondResult.addedFiles.isEmpty)
        #expect(secondResult.modifiedFiles.isEmpty)
        #expect(secondResult.unchangedFiles.count == 1)
        #expect(!secondResult.hasChanges)
    }

    @Test("Detects modified file")
    func changeDetectorDetectsModifiedFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("Test.swift")
        try "let x = 1".write(to: testFile, atomically: true, encoding: .utf8)

        let detector = ChangeDetector(configuration: .strict)

        // Get initial state
        let firstResult = await detector.detectChanges(
            currentFiles: [testFile.path],
            previousState: [:],
        )

        var previousState: [String: FileState] = [:]
        for change in firstResult.changes {
            if let state = change.currentState {
                previousState[change.path] = state
            }
        }

        // Modify the file
        try "let x = 2".write(to: testFile, atomically: true, encoding: .utf8)

        // Detect changes
        let secondResult = await detector.detectChanges(
            currentFiles: [testFile.path],
            previousState: previousState,
        )

        #expect(secondResult.modifiedFiles.count == 1)
        #expect(secondResult.hasChanges)
    }

    @Test("Detects deleted file")
    func changeDetectorDetectsDeletedFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("Test.swift")
        try "let x = 1".write(to: testFile, atomically: true, encoding: .utf8)

        let detector = ChangeDetector()

        // Get initial state
        let firstResult = await detector.detectChanges(
            currentFiles: [testFile.path],
            previousState: [:],
        )

        var previousState: [String: FileState] = [:]
        for change in firstResult.changes {
            if let state = change.currentState {
                previousState[change.path] = state
            }
        }

        // Delete the file
        try FileManager.default.removeItem(at: testFile)

        // Detect changes with empty current files
        let secondResult = await detector.detectChanges(
            currentFiles: [],
            previousState: previousState,
        )

        #expect(secondResult.deletedFiles.count == 1)
        #expect(secondResult.hasChanges)
    }
}

// MARK: - FNV1aHashTests

@Suite("FNV1a Hash Tests")
struct FNV1aHashTests {
    @Test("Hash consistency")
    func hashConsistency() {
        let data = "Hello, World!".data(using: .utf8)!
        let hash1 = FNV1a.hash(data)
        let hash2 = FNV1a.hash(data)
        #expect(hash1 == hash2)
    }

    @Test("Different data produces different hash")
    func differentDataDifferentHash() {
        let data1 = "Hello".data(using: .utf8)!
        let data2 = "World".data(using: .utf8)!
        #expect(FNV1a.hash(data1) != FNV1a.hash(data2))
    }

    @Test("String hashing")
    func stringHashing() {
        let hash1 = FNV1a.hash("test")
        let hash2 = FNV1a.hash("test")
        #expect(hash1 == hash2)
    }

    @Test("Array hashing")
    func arrayHashing() {
        let hash1 = FNV1a.hash(["a", "b", "c"])
        let hash2 = FNV1a.hash(["a", "b", "c"])
        #expect(hash1 == hash2)

        let hash3 = FNV1a.hash(["a", "b", "d"])
        #expect(hash1 != hash3)
    }
}

// MARK: - AnalysisCacheTests

@Suite("Analysis Cache Tests")
struct AnalysisCacheTests {
    @Test("Cache stores and retrieves")
    func cacheStoresAndRetrieves() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = AnalysisCache(cacheDirectory: tempDir)

        let fileState = FileState(
            path: "/test/file.swift",
            contentHash: 12345,
            modificationTime: Date(),
            size: 100,
        )

        await cache.setFileState(fileState, for: fileState.path)

        let retrieved = await cache.getFileState(for: fileState.path)
        #expect(retrieved?.contentHash == fileState.contentHash)
    }

    @Test("Cache persistence")
    func cachePersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create and populate cache
        let cache1 = AnalysisCache(cacheDirectory: tempDir)
        let fileState = FileState(
            path: "/test/file.swift",
            contentHash: 12345,
            modificationTime: Date(),
            size: 100,
        )
        await cache1.setFileState(fileState, for: fileState.path)
        try await cache1.save()

        // Load in new cache instance
        let cache2 = AnalysisCache(cacheDirectory: tempDir)
        try await cache2.load()

        let retrieved = await cache2.getFileState(for: fileState.path)
        #expect(retrieved?.contentHash == fileState.contentHash)
    }

    @Test("Cache statistics")
    func cacheStatistics() async {
        let cache = AnalysisCache()

        await cache.setFileState(
            FileState(path: "/a.swift", contentHash: 1, modificationTime: Date(), size: 10),
            for: "/a.swift",
        )
        await cache.setFileState(
            FileState(path: "/b.swift", contentHash: 2, modificationTime: Date(), size: 20),
            for: "/b.swift",
        )

        let stats = await cache.statistics()
        #expect(stats.fileCount == 2)
    }
}

// MARK: - DependencyGraphTests

@Suite("Dependency Graph Tests")
struct DependencyGraphTests {
    @Test("Direct dependents")
    func directDependents() {
        var graph = DependencyGraph()

        graph.addDependency(
            FileDependency(
                dependentFile: "/a.swift",
                dependencyFile: "/b.swift",
                type: .typeReference,
            ))

        #expect(graph.getDirectDependents(of: "/b.swift") == ["/a.swift"])
        #expect(graph.getDirectDependencies(of: "/a.swift") == ["/b.swift"])
    }

    @Test("Transitive affected files")
    func transitiveAffectedFiles() {
        var graph = DependencyGraph()

        // a -> b -> c
        graph.addDependency(
            FileDependency(
                dependentFile: "/a.swift",
                dependencyFile: "/b.swift",
                type: .typeReference,
            ))
        graph.addDependency(
            FileDependency(
                dependentFile: "/b.swift",
                dependencyFile: "/c.swift",
                type: .typeReference,
            ))

        // If c changes, both a and b should be affected
        let affected = graph.getAffectedFiles(changedFiles: ["/c.swift"])
        #expect(affected.contains("/a.swift"))
        #expect(affected.contains("/b.swift"))
        #expect(affected.contains("/c.swift"))
    }

    @Test("Remove dependencies")
    func removeDependencies() {
        var graph = DependencyGraph()

        graph.addDependency(
            FileDependency(
                dependentFile: "/a.swift",
                dependencyFile: "/b.swift",
                type: .typeReference,
            ))

        #expect(graph.getDirectDependents(of: "/b.swift").count == 1)

        graph.removeDependencies(for: "/a.swift")

        #expect(graph.getDirectDependents(of: "/b.swift").isEmpty)
    }
}

// MARK: - CachedDeclarationTests

@Suite("Cached Declaration Tests")
struct CachedDeclarationTests {
    @Test("CachedDeclaration from Declaration")
    func cachedDeclarationFromDeclaration() {
        let declaration = Declaration(
            name: "testFunc",
            kind: .function,
            accessLevel: .internal,
            modifiers: [.static],
            location: SourceLocation(file: "/test.swift", line: 10, column: 5),
            range: SourceRange(
                start: SourceLocation(file: "/test.swift", line: 10, column: 5),
                end: SourceLocation(file: "/test.swift", line: 15, column: 1),
            ),
            scope: ScopeID("global"),
            conformances: ["Sendable"],
        )

        let cached = CachedDeclaration(from: declaration)

        #expect(cached.name == "testFunc")
        #expect(cached.kind == "function")
        #expect(cached.file == "/test.swift")
        #expect(cached.line == 10)
        #expect(cached.conformances == ["Sendable"])
    }
}

// MARK: - CachedReferenceTests

@Suite("Cached Reference Tests")
struct CachedReferenceTests {
    @Test("CachedReference from Reference")
    func cachedReferenceFromReference() {
        let reference = Reference(
            identifier: "SomeType",
            location: SourceLocation(file: "/test.swift", line: 5, column: 10),
            scope: ScopeID("func_body"),
            context: .typeAnnotation,
            isQualified: true,
            qualifier: "Module",
        )

        let cached = CachedReference(from: reference)

        #expect(cached.identifier == "SomeType")
        #expect(cached.file == "/test.swift")
        #expect(cached.context == "typeAnnotation")
        #expect(cached.isQualified)
        #expect(cached.qualifier == "Module")
    }
}
