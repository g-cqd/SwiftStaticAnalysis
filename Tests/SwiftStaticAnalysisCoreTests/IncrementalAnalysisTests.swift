//
//  IncrementalAnalysisTests.swift
//  SwiftStaticAnalysis
//
//  Tests for incremental analysis framework.
//

import XCTest
@testable import SwiftStaticAnalysisCore

final class ChangeDetectorTests: XCTestCase {

    func testChangeDetectorFindsNoChangesForSameFiles() async throws {
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
            previousState: [:]
        )

        XCTAssertEqual(firstState.addedFiles.count, 1)
        XCTAssertEqual(firstState.modifiedFiles.count, 0)
        XCTAssertEqual(firstState.unchangedFiles.count, 0)

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
            previousState: previousState
        )

        XCTAssertEqual(secondResult.addedFiles.count, 0)
        XCTAssertEqual(secondResult.modifiedFiles.count, 0)
        XCTAssertEqual(secondResult.unchangedFiles.count, 1)
        XCTAssertFalse(secondResult.hasChanges)
    }

    func testChangeDetectorDetectsModifiedFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("Test.swift")
        try "let x = 1".write(to: testFile, atomically: true, encoding: .utf8)

        let detector = ChangeDetector(configuration: .strict)

        // Get initial state
        let firstResult = await detector.detectChanges(
            currentFiles: [testFile.path],
            previousState: [:]
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
            previousState: previousState
        )

        XCTAssertEqual(secondResult.modifiedFiles.count, 1)
        XCTAssertTrue(secondResult.hasChanges)
    }

    func testChangeDetectorDetectsDeletedFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("Test.swift")
        try "let x = 1".write(to: testFile, atomically: true, encoding: .utf8)

        let detector = ChangeDetector()

        // Get initial state
        let firstResult = await detector.detectChanges(
            currentFiles: [testFile.path],
            previousState: [:]
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
            previousState: previousState
        )

        XCTAssertEqual(secondResult.deletedFiles.count, 1)
        XCTAssertTrue(secondResult.hasChanges)
    }
}

final class FNV1aHashTests: XCTestCase {

    func testHashConsistency() {
        let data = "Hello, World!".data(using: .utf8)!
        let hash1 = FNV1a.hash(data)
        let hash2 = FNV1a.hash(data)
        XCTAssertEqual(hash1, hash2)
    }

    func testDifferentDataDifferentHash() {
        let data1 = "Hello".data(using: .utf8)!
        let data2 = "World".data(using: .utf8)!
        XCTAssertNotEqual(FNV1a.hash(data1), FNV1a.hash(data2))
    }

    func testStringHashing() {
        let hash1 = FNV1a.hash("test")
        let hash2 = FNV1a.hash("test")
        XCTAssertEqual(hash1, hash2)
    }

    func testArrayHashing() {
        let hash1 = FNV1a.hash(["a", "b", "c"])
        let hash2 = FNV1a.hash(["a", "b", "c"])
        XCTAssertEqual(hash1, hash2)

        let hash3 = FNV1a.hash(["a", "b", "d"])
        XCTAssertNotEqual(hash1, hash3)
    }
}

final class AnalysisCacheTests: XCTestCase {

    func testCacheStoresAndRetrieves() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = AnalysisCache(cacheDirectory: tempDir)

        let fileState = FileState(
            path: "/test/file.swift",
            contentHash: 12345,
            modificationTime: Date(),
            size: 100
        )

        await cache.setFileState(fileState, for: fileState.path)

        let retrieved = await cache.getFileState(for: fileState.path)
        XCTAssertEqual(retrieved?.contentHash, fileState.contentHash)
    }

    func testCachePersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create and populate cache
        let cache1 = AnalysisCache(cacheDirectory: tempDir)
        let fileState = FileState(
            path: "/test/file.swift",
            contentHash: 12345,
            modificationTime: Date(),
            size: 100
        )
        await cache1.setFileState(fileState, for: fileState.path)
        try await cache1.save()

        // Load in new cache instance
        let cache2 = AnalysisCache(cacheDirectory: tempDir)
        try await cache2.load()

        let retrieved = await cache2.getFileState(for: fileState.path)
        XCTAssertEqual(retrieved?.contentHash, fileState.contentHash)
    }

    func testCacheStatistics() async {
        let cache = AnalysisCache()

        await cache.setFileState(
            FileState(path: "/a.swift", contentHash: 1, modificationTime: Date(), size: 10),
            for: "/a.swift"
        )
        await cache.setFileState(
            FileState(path: "/b.swift", contentHash: 2, modificationTime: Date(), size: 20),
            for: "/b.swift"
        )

        let stats = await cache.statistics()
        XCTAssertEqual(stats.fileCount, 2)
    }
}

final class DependencyGraphTests: XCTestCase {

    func testDirectDependents() {
        var graph = DependencyGraph()

        graph.addDependency(FileDependency(
            dependentFile: "/a.swift",
            dependencyFile: "/b.swift",
            type: .typeReference
        ))

        XCTAssertEqual(graph.getDirectDependents(of: "/b.swift"), ["/a.swift"])
        XCTAssertEqual(graph.getDirectDependencies(of: "/a.swift"), ["/b.swift"])
    }

    func testTransitiveAffectedFiles() {
        var graph = DependencyGraph()

        // a -> b -> c
        graph.addDependency(FileDependency(
            dependentFile: "/a.swift",
            dependencyFile: "/b.swift",
            type: .typeReference
        ))
        graph.addDependency(FileDependency(
            dependentFile: "/b.swift",
            dependencyFile: "/c.swift",
            type: .typeReference
        ))

        // If c changes, both a and b should be affected
        let affected = graph.getAffectedFiles(changedFiles: ["/c.swift"])
        XCTAssertTrue(affected.contains("/a.swift"))
        XCTAssertTrue(affected.contains("/b.swift"))
        XCTAssertTrue(affected.contains("/c.swift"))
    }

    func testRemoveDependencies() {
        var graph = DependencyGraph()

        graph.addDependency(FileDependency(
            dependentFile: "/a.swift",
            dependencyFile: "/b.swift",
            type: .typeReference
        ))

        XCTAssertEqual(graph.getDirectDependents(of: "/b.swift").count, 1)

        graph.removeDependencies(for: "/a.swift")

        XCTAssertEqual(graph.getDirectDependents(of: "/b.swift").count, 0)
    }
}

final class CachedDeclarationTests: XCTestCase {

    func testCachedDeclarationFromDeclaration() {
        let declaration = Declaration(
            name: "testFunc",
            kind: .function,
            accessLevel: .internal,
            modifiers: [.static],
            location: SourceLocation(file: "/test.swift", line: 10, column: 5),
            range: SourceRange(
                start: SourceLocation(file: "/test.swift", line: 10, column: 5),
                end: SourceLocation(file: "/test.swift", line: 15, column: 1)
            ),
            scope: ScopeID("global"),
            conformances: ["Sendable"]
        )

        let cached = CachedDeclaration(from: declaration)

        XCTAssertEqual(cached.name, "testFunc")
        XCTAssertEqual(cached.kind, "function")
        XCTAssertEqual(cached.file, "/test.swift")
        XCTAssertEqual(cached.line, 10)
        XCTAssertEqual(cached.conformances, ["Sendable"])
    }
}

final class CachedReferenceTests: XCTestCase {

    func testCachedReferenceFromReference() {
        let reference = Reference(
            identifier: "SomeType",
            location: SourceLocation(file: "/test.swift", line: 5, column: 10),
            scope: ScopeID("func_body"),
            context: .typeAnnotation,
            isQualified: true,
            qualifier: "Module"
        )

        let cached = CachedReference(from: reference)

        XCTAssertEqual(cached.identifier, "SomeType")
        XCTAssertEqual(cached.file, "/test.swift")
        XCTAssertEqual(cached.context, "typeAnnotation")
        XCTAssertTrue(cached.isQualified)
        XCTAssertEqual(cached.qualifier, "Module")
    }
}
