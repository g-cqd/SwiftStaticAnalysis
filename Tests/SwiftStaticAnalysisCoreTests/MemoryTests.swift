//
//  MemoryTests.swift
//  SwiftStaticAnalysis
//
//  Tests for arena allocation, memory-mapped files, and SoA token storage.
//

import Foundation
@testable import SwiftStaticAnalysisCore
import Testing

// MARK: - ArenaAllocationTests

@Suite("Arena Allocation Tests")
struct ArenaAllocationTests {
    @Test("Arena can allocate raw memory")
    func basicAllocation() {
        let arena = Arena()
        _ = arena.allocate(size: 100, alignment: 8)
        #expect(arena.totalAllocations == 1)
        #expect(arena.totalBytesAllocated >= 100)
    }

    @Test("Arena can allocate typed memory")
    func typedAllocation() {
        let arena = Arena()
        let buffer: UnsafeMutableBufferPointer<Int> = arena.allocate(count: 10)
        #expect(buffer.count == 10)

        // Write and verify
        for i in 0 ..< 10 {
            buffer[i] = i * 10
        }
        for i in 0 ..< 10 {
            #expect(buffer[i] == i * 10)
        }
    }

    @Test("Arena store and copy work correctly")
    func storeAndCopy() {
        let arena = Arena()

        // Store single value
        let ptr = arena.store(42)
        #expect(ptr.pointee == 42)

        // Copy array
        let array = [1, 2, 3, 4, 5]
        let copied = arena.copy(array)
        #expect(copied.count == 5)
        for (i, element) in array.enumerated() {
            #expect(copied[i] == element)
        }
    }

    @Test("Arena reset clears allocations but keeps capacity")
    func reset() {
        let arena = Arena()

        // Make some allocations
        for _ in 0 ..< 100 {
            arena.allocate(size: 1000, alignment: 8)
        }

        let blockCount = arena.blockCount
        #expect(arena.totalBytesAllocated > 0)

        // Reset
        arena.reset()
        #expect(arena.totalBytesAllocated == 0)
        #expect(arena.blockCount == blockCount) // Blocks kept
    }

    @Test("Arena release frees all memory")
    func release() {
        let arena = Arena()

        // Make some allocations
        for _ in 0 ..< 10 {
            arena.allocate(size: 10000, alignment: 8)
        }

        #expect(arena.blockCount > 0)

        // Release
        arena.release()
        #expect(arena.blockCount == 0)
        #expect(arena.totalBytesAllocated == 0)
    }

    @Test("Arena handles large allocations")
    func largeAllocation() {
        let arena = Arena(configuration: ArenaConfiguration(blockSize: 1024))

        // Allocate more than block size
        _ = arena.allocate(size: 10000, alignment: 8)
        #expect(arena.totalBytesAllocated >= 10000)
    }

    @Test("Arena respects alignment")
    func alignment() {
        let arena = Arena()

        // Various alignments
        for alignment in [1, 2, 4, 8, 16, 32] {
            let ptr = arena.allocate(size: 1, alignment: alignment)
            let address = Int(bitPattern: ptr)
            #expect(address % alignment == 0, "Pointer should be aligned to \(alignment)")
        }
    }

    @Test("Arena scoped allocation resets correctly")
    func scopedAllocation() {
        let arena = Arena()

        // Pre-scope allocation
        arena.allocate(size: 100, alignment: 8)
        let preScopeBlockCount = arena.blockCount

        // Scoped allocation
        let result = arena.withScope { scoped in
            scoped.allocate(size: 1000, alignment: 8)
            scoped.allocate(size: 2000, alignment: 8)
            return 42
        }

        #expect(result == 42)
        // Block count should remain stable (blocks are reused, not deallocated)
        #expect(arena.blockCount >= preScopeBlockCount)

        // Verify memory can be reused after scope
        // This allocation should fit in existing blocks if scope reset worked
        arena.allocate(size: 500, alignment: 8)
        #expect(arena.totalAllocations >= 4)
    }

    @Test("Arena statistics are accurate")
    func statistics() {
        let arena = Arena()

        arena.allocate(size: 100, alignment: 8)
        arena.allocate(size: 200, alignment: 8)
        arena.allocate(size: 300, alignment: 8)

        #expect(arena.totalAllocations == 3)
        #expect(arena.totalBytesAllocated >= 600)
        #expect(arena.peakBytesAllocated >= arena.totalBytesAllocated)
        #expect(arena.utilization > 0)
    }
}

// MARK: - ArenaAllocatableTests

@Suite("Arena Allocatable Tests")
struct ArenaAllocatableTests {
    @Test("Primitive types are arena allocatable")
    func primitiveTypes() {
        let arena = Arena()

        let ints: UnsafeMutableBufferPointer<Int> = Int.allocate(in: arena, count: 10)
        #expect(ints.count == 10)

        let doubles: UnsafeMutableBufferPointer<Double> = Double.allocate(in: arena, count: 5)
        #expect(doubles.count == 5)

        let bools: UnsafeMutableBufferPointer<Bool> = Bool.allocate(in: arena, count: 20)
        #expect(bools.count == 20)
    }
}

// MARK: - ThreadLocalArenaTests

@Suite("Thread Local Arena Tests")
struct ThreadLocalArenaTests {
    @Test("Thread local arena provides arena for current thread")
    func currentArena() {
        let arena = ThreadLocalArena.current

        // Same thread should get same arena
        let arena2 = ThreadLocalArena.current
        #expect(arena === arena2)
    }

    @Test("Thread local arena reset works")
    func tlsReset() {
        let arena = ThreadLocalArena.current
        arena.allocate(size: 1000, alignment: 8)
        #expect(arena.totalBytesAllocated > 0)

        ThreadLocalArena.reset()
        #expect(arena.totalBytesAllocated == 0)
    }
}

// MARK: - MemoryMappedFileTests

@Suite("Memory Mapped File Tests")
struct MemoryMappedFileTests {
    // Helper to create a temporary file
    func createTempFile(content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).txt"
        let path = tempDir.appendingPathComponent(fileName).path

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // Helper to delete temp file
    func deleteTempFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Memory mapped file can be created")
    func creation() throws {
        let content = "Hello, World!\nThis is a test file.\nLine three."
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        #expect(mmf.size == content.utf8.count)
        #expect(mmf.path == path)
    }

    @Test("Memory mapped file provides correct content")
    func readContent() throws {
        let content = "Swift is great for static analysis!"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        let read = mmf.readAsString()
        #expect(read == content)
    }

    @Test("File slice provides zero-copy access")
    func sliceAccess() throws {
        let content = "0123456789ABCDEF"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)

        let slice = mmf.slice(offset: 5, length: 5)
        #expect(slice.length == 5)
        #expect(slice.asString() == "56789")
    }

    @Test("File subscript access works")
    func subscriptAccess() throws {
        let content = "ABCDE"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)

        #expect(mmf[0] == 65) // 'A'
        #expect(mmf[4] == 69) // 'E'
        #expect(mmf[5] == nil) // Out of range
    }

    @Test("Line ranges are computed correctly")
    func lineRanges() throws {
        let content = "Line 1\nLine 2\nLine 3"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        let ranges = mmf.findLineRanges()

        #expect(ranges.count == 3)
        #expect(mmf.slice(offset: ranges[0].offset, length: ranges[0].length).asString() == "Line 1")
        #expect(mmf.slice(offset: ranges[1].offset, length: ranges[1].length).asString() == "Line 2")
        #expect(mmf.slice(offset: ranges[2].offset, length: ranges[2].length).asString() == "Line 3")
    }

    @Test("Getting specific line works")
    func lineAccess() throws {
        let content = "First\nSecond\nThird"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)

        #expect(mmf.line(0)?.asString() == "First")
        #expect(mmf.line(1)?.asString() == "Second")
        #expect(mmf.line(2)?.asString() == "Third")
        #expect(mmf.line(3) == nil)
    }

    @Test("Non-existent file throws error")
    func nonExistentFile() {
        #expect(throws: MemoryMappedFileError.self) {
            _ = try MemoryMappedFile(path: "/non/existent/path.txt")
        }
    }

    @Test("Empty file throws error")
    func emptyFile() throws {
        let path = try createTempFile(content: "")
        defer { deleteTempFile(path) }

        #expect(throws: MemoryMappedFileError.self) {
            _ = try MemoryMappedFile(path: path)
        }
    }
}

// MARK: - FileSliceTests

@Suite("File Slice Tests")
struct FileSliceTests {
    func createTempFile(content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).txt"
        let path = tempDir.appendingPathComponent(fileName).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func deleteTempFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Slice can create subslice")
    func subslice() throws {
        let content = "0123456789"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        let slice = mmf.fullSlice
        let sub = slice.subslice(offset: 2, length: 5)

        #expect(sub.length == 5)
        #expect(sub.asString() == "23456")
    }

    @Test("Slice hash is consistent")
    func sliceHash() throws {
        let content = "TestContent"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        let slice1 = mmf.fullSlice
        let slice2 = mmf.fullSlice

        #expect(slice1.hash() == slice2.hash())
    }

    @Test("Slice equality comparison works")
    func sliceEquality() throws {
        let content = "ABCABC"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        let slice1 = mmf.slice(offset: 0, length: 3)
        let slice2 = mmf.slice(offset: 3, length: 3)

        #expect(slice1.equals(slice2))
        #expect(slice1.equals("ABC"))
    }

    @Test("Slice asBytes creates correct array")
    func sliceToBytes() throws {
        let content = "ABC"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        let bytes = mmf.fullSlice.asBytes()

        #expect(bytes == [65, 66, 67])
    }
}

// MARK: - TokenSliceTests

@Suite("Token Slice Tests")
struct TokenSliceTests {
    func createTempFile(content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).txt"
        let path = tempDir.appendingPathComponent(fileName).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func deleteTempFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Token slice stores correct data")
    func tokenSliceData() {
        let slice = TokenSlice(offset: 10, length: 5, line: 3, column: 8)
        #expect(slice.offset == 10)
        #expect(slice.length == 5)
        #expect(slice.line == 3)
        #expect(slice.column == 8)
    }

    @Test("Token slice can extract text from mapped file")
    func tokenSliceText() throws {
        let content = "func hello() {}"
        let path = try createTempFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        let slice = TokenSlice(offset: 5, length: 5, line: 1, column: 6)

        #expect(slice.text(from: mmf) == "hello")
    }
}

// MARK: - SoATokenStorageTests

@Suite("SoA Token Storage Tests")
struct SoATokenStorageTests {
    @Test("Empty storage has correct initial state")
    func emptyStorage() {
        let storage = SoATokenStorage()
        #expect(storage.isEmpty)
        #expect(storage.isEmpty)
    }

    @Test("Append adds tokens correctly")
    func appendTokens() {
        var storage = SoATokenStorage()

        storage.append(kind: .keyword, offset: 0, length: 4, line: 1, column: 1)
        storage.append(kind: .identifier, offset: 5, length: 3, line: 1, column: 6)
        storage.append(kind: .punctuation, offset: 8, length: 1, line: 1, column: 9)

        #expect(storage.count == 3)
        #expect(storage.kind(at: 0) == .keyword)
        #expect(storage.kind(at: 1) == .identifier)
        #expect(storage.kind(at: 2) == .punctuation)
    }

    @Test("Token access methods work correctly")
    func tokenAccess() {
        var storage = SoATokenStorage()
        storage.append(kind: .literal, offset: 100, length: 50, line: 10, column: 20)

        #expect(storage.kind(at: 0) == .literal)
        #expect(storage.offset(at: 0) == 100)
        #expect(storage.length(at: 0) == 50)
        #expect(storage.line(at: 0) == 10)
        #expect(storage.column(at: 0) == 20)
    }

    @Test("Reserve capacity works")
    func reserveCapacity() {
        var storage = SoATokenStorage()
        storage.reserveCapacity(1000)

        // Should be able to add without reallocation
        for i in 0 ..< 1000 {
            storage.append(kind: .identifier, offset: i, length: 1, line: 1)
        }

        #expect(storage.count == 1000)
    }

    @Test("RemoveAll clears storage")
    func removeAll() {
        var storage = SoATokenStorage()
        for i in 0 ..< 100 {
            storage.append(kind: .keyword, offset: i, length: 1, line: 1)
        }

        storage.removeAll()
        #expect(storage.isEmpty)
        #expect(storage.isEmpty)
    }

    @Test("Indices with kind returns correct indices")
    func indicesWithKind() {
        var storage = SoATokenStorage()
        storage.append(kind: .keyword, offset: 0, length: 1, line: 1)
        storage.append(kind: .identifier, offset: 1, length: 1, line: 1)
        storage.append(kind: .keyword, offset: 2, length: 1, line: 1)
        storage.append(kind: .identifier, offset: 3, length: 1, line: 1)
        storage.append(kind: .keyword, offset: 4, length: 1, line: 1)

        let keywordIndices = storage.indicesWithKind(.keyword)
        #expect(keywordIndices == [0, 2, 4])

        let identifierIndices = storage.indicesWithKind(.identifier)
        #expect(identifierIndices == [1, 3])
    }

    @Test("Count by kind works correctly")
    func countByKind() {
        var storage = SoATokenStorage()
        storage.append(kind: .keyword, offset: 0, length: 1, line: 1)
        storage.append(kind: .keyword, offset: 1, length: 1, line: 1)
        storage.append(kind: .identifier, offset: 2, length: 1, line: 1)
        storage.append(kind: .literal, offset: 3, length: 1, line: 1)
        storage.append(kind: .literal, offset: 4, length: 1, line: 1)
        storage.append(kind: .literal, offset: 5, length: 1, line: 1)

        let counts = storage.countByKind()
        #expect(counts[Int(TokenKindByte.keyword.rawValue)] == 2)
        #expect(counts[Int(TokenKindByte.identifier.rawValue)] == 1)
        #expect(counts[Int(TokenKindByte.literal.rawValue)] == 3)
    }

    @Test("Tokens in line range works")
    func tokensInLineRange() {
        var storage = SoATokenStorage()
        storage.append(kind: .keyword, offset: 0, length: 1, line: 1)
        storage.append(kind: .keyword, offset: 1, length: 1, line: 2)
        storage.append(kind: .keyword, offset: 2, length: 1, line: 3)
        storage.append(kind: .keyword, offset: 3, length: 1, line: 4)
        storage.append(kind: .keyword, offset: 4, length: 1, line: 5)

        let range = storage.tokensInLineRange(2 ... 4)
        #expect(range == 1 ..< 4)
    }

    @Test("Hash range produces consistent hash")
    func hashRange() {
        var storage = SoATokenStorage()
        storage.append(kind: .keyword, offset: 0, length: 4, line: 1)
        storage.append(kind: .identifier, offset: 5, length: 3, line: 1)

        let hash1 = storage.hashRange(0 ..< 2)
        let hash2 = storage.hashRange(0 ..< 2)

        #expect(hash1 == hash2)
    }

    @Test("Ranges equal comparison works")
    func rangesEqual() {
        var storage = SoATokenStorage()
        storage.append(kind: .keyword, offset: 0, length: 4, line: 1)
        storage.append(kind: .identifier, offset: 5, length: 3, line: 1)
        storage.append(kind: .keyword, offset: 10, length: 4, line: 2)
        storage.append(kind: .identifier, offset: 15, length: 3, line: 2)

        #expect(storage.rangesEqual(0 ..< 2, 2 ..< 4))
    }

    @Test("Memory usage is calculated correctly")
    func memoryUsage() {
        var storage = SoATokenStorage()
        for i in 0 ..< 100 {
            storage.append(kind: .keyword, offset: i, length: 1, line: 1)
        }

        // Each token: 1 (kind) + 4 (offset) + 2 (length) + 4 (line) + 2 (column) = 13 bytes
        #expect(storage.memoryUsage == 100 * 13)
        #expect(storage.bytesPerToken == 13)
    }

    @Test("Create from array works")
    func createFromArray() {
        let tokens: [(kind: TokenKindByte, offset: Int, length: Int, line: Int, column: Int)] = [
            (.keyword, 0, 4, 1, 1),
            (.identifier, 5, 3, 1, 6),
            (.punctuation, 8, 1, 1, 9),
        ]

        let storage = SoATokenStorage.from(tokens)
        #expect(storage.count == 3)
        #expect(storage.kind(at: 0) == .keyword)
        #expect(storage.kind(at: 1) == .identifier)
        #expect(storage.kind(at: 2) == .punctuation)
    }
}

// MARK: - ArenaTokenStorageTests

@Suite("Arena Token Storage Tests")
struct ArenaTokenStorageTests {
    @Test("Arena token storage copies from SoA storage")
    func copyFromSoA() {
        var soaStorage = SoATokenStorage()
        soaStorage.append(kind: .keyword, offset: 0, length: 4, line: 1)
        soaStorage.append(kind: .identifier, offset: 5, length: 3, line: 1)

        let arena = Arena()
        let arenaStorage = ArenaTokenStorage(from: soaStorage, arena: arena)

        #expect(arenaStorage.count == 2)
        #expect(arenaStorage.kind(at: 0) == .keyword)
        #expect(arenaStorage.kind(at: 1) == .identifier)
        #expect(arenaStorage.offset(at: 0) == 0)
        #expect(arenaStorage.length(at: 1) == 3)
    }
}

// MARK: - MultiFileSoAStorageTests

@Suite("Multi-File SoA Storage Tests")
struct MultiFileSoAStorageTests {
    @Test("Empty multi-file storage has correct initial state")
    func emptyMultiFile() {
        let storage = MultiFileSoAStorage()
        #expect(storage.fileCount == 0)
        #expect(storage.totalTokenCount == 0)
    }

    @Test("Adding files works correctly")
    func addFiles() {
        var multi = MultiFileSoAStorage()

        var tokens1 = SoATokenStorage()
        tokens1.append(kind: .keyword, offset: 0, length: 4, line: 1)
        tokens1.append(kind: .identifier, offset: 5, length: 3, line: 1)
        multi.addFile(path: "file1.swift", tokens: tokens1)

        var tokens2 = SoATokenStorage()
        tokens2.append(kind: .literal, offset: 0, length: 5, line: 1)
        multi.addFile(path: "file2.swift", tokens: tokens2)

        #expect(multi.fileCount == 2)
        #expect(multi.totalTokenCount == 3)
    }

    @Test("File token ranges are correct")
    func fileTokenRanges() {
        var multi = MultiFileSoAStorage()

        var tokens1 = SoATokenStorage()
        for i in 0 ..< 5 {
            tokens1.append(kind: .keyword, offset: i, length: 1, line: 1)
        }
        multi.addFile(path: "file1.swift", tokens: tokens1)

        var tokens2 = SoATokenStorage()
        for i in 0 ..< 3 {
            tokens2.append(kind: .identifier, offset: i, length: 1, line: 1)
        }
        multi.addFile(path: "file2.swift", tokens: tokens2)

        let range1 = multi.tokens(forFile: 0)
        #expect(range1.start == 0)
        #expect(range1.end == 5)

        let range2 = multi.tokens(forFile: 1)
        #expect(range2.start == 6) // After boundary marker
        #expect(range2.end == 9)
    }

    @Test("File index for token works")
    func fileIndexForToken() {
        var multi = MultiFileSoAStorage()

        var tokens1 = SoATokenStorage()
        for i in 0 ..< 5 {
            tokens1.append(kind: .keyword, offset: i, length: 1, line: 1)
        }
        multi.addFile(path: "file1.swift", tokens: tokens1)

        var tokens2 = SoATokenStorage()
        for i in 0 ..< 3 {
            tokens2.append(kind: .identifier, offset: i, length: 1, line: 1)
        }
        multi.addFile(path: "file2.swift", tokens: tokens2)

        #expect(multi.fileIndex(forToken: 0) == 0)
        #expect(multi.fileIndex(forToken: 4) == 0)
        #expect(multi.fileIndex(forToken: 6) == 1)
        #expect(multi.fileIndex(forToken: 8) == 1)
    }
}

// MARK: - TokenKindByteTests

@Suite("Token Kind Byte Tests")
struct TokenKindByteTests {
    @Test("Token kind byte constants have correct values")
    func tokenKindByteValues() {
        #expect(TokenKindByte.keyword.rawValue == 0)
        #expect(TokenKindByte.identifier.rawValue == 1)
        #expect(TokenKindByte.literal.rawValue == 2)
        #expect(TokenKindByte.operator.rawValue == 3)
        #expect(TokenKindByte.punctuation.rawValue == 4)
        #expect(TokenKindByte.unknown.rawValue == 5)
        #expect(TokenKindByte.fileBoundary.rawValue == 255)
    }

    @Test("Token kind byte is equatable")
    func tokenKindByteEquatable() {
        #expect(TokenKindByte.keyword == TokenKindByte.keyword)
        #expect(TokenKindByte.keyword != TokenKindByte.identifier)
    }

    @Test("Token kind byte is hashable")
    func tokenKindByteHashable() {
        var set = Set<TokenKindByte>()
        set.insert(.keyword)
        set.insert(.identifier)
        set.insert(.keyword) // Duplicate

        #expect(set.count == 2)
    }
}

// MARK: - ZeroCopyParserTests

@Suite("Zero-Copy Parser Tests")
struct ZeroCopyParserTests {
    func createTempSwiftFile(content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).swift"
        let path = tempDir.appendingPathComponent(fileName).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func deleteTempFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Zero-copy parser can parse Swift file")
    func basicParsing() async throws {
        let content = """
        func hello() {
            print("Hello")
        }
        """
        let path = try createTempSwiftFile(content: content)
        defer { deleteTempFile(path) }

        let parser = ZeroCopyParser()
        let result = try await parser.parse(path)

        #expect(result.path == path)
        #expect(!result.tokens.isEmpty)
        #expect(result.syntaxTree != nil)
    }

    @Test("Zero-copy parser extracts correct tokens")
    func tokenExtraction() async throws {
        let content = "let x = 42"
        let path = try createTempSwiftFile(content: content)
        defer { deleteTempFile(path) }

        let parser = ZeroCopyParser()
        let result = try await parser.parse(path)

        // Should have: let (keyword), x (identifier), = (operator), 42 (literal)
        #expect(result.tokens.count >= 4)

        // Check token kinds
        let kinds = (0 ..< result.tokens.count).map { result.tokens.kind(at: $0) }
        #expect(kinds.contains(.keyword))
        #expect(kinds.contains(.identifier))
        #expect(kinds.contains(.literal))
    }

    @Test("Zero-copy parser caches results")
    func caching() async throws {
        let content = "var y = 100"
        let path = try createTempSwiftFile(content: content)
        defer { deleteTempFile(path) }

        let parser = ZeroCopyParser()

        _ = try await parser.parse(path)
        let cacheSize1 = await parser.cacheSize

        _ = try await parser.parse(path)
        let cacheSize2 = await parser.cacheSize

        #expect(cacheSize1 == 1)
        #expect(cacheSize2 == 1) // Same entry reused
    }

    @Test("Zero-copy parser cache can be cleared")
    func cacheClear() async throws {
        let content = "let z = true"
        let path = try createTempSwiftFile(content: content)
        defer { deleteTempFile(path) }

        let parser = ZeroCopyParser()
        _ = try await parser.parse(path)

        await parser.clearCache()
        let cacheSize = await parser.cacheSize

        #expect(cacheSize == 0)
    }

    @Test("Small files use regular I/O")
    func smallFileHandling() async throws {
        let content = "x" // Very small file
        let path = try createTempSwiftFile(content: content)
        defer { deleteTempFile(path) }

        let config = ZeroCopyParserConfiguration(mmapThreshold: 1000)
        let parser = ZeroCopyParser(configuration: config)
        let result = try await parser.parse(path)

        // Small file should not use mmap
        #expect(result.mappedSource == nil)
        #expect(result.sourceString != nil)
    }

    @Test("Code snippet extraction works")
    func snippetExtraction() async throws {
        let content = """
        line 1
        line 2
        line 3
        """
        let path = try createTempSwiftFile(content: content)
        defer { deleteTempFile(path) }

        let parser = ZeroCopyParser()
        let result = try await parser.parse(path)

        let snippet = result.snippet(startLine: 2, endLine: 2)
        #expect(snippet.contains("line 2"))
    }
}

// MARK: - BatchTokenExtractorTests

@Suite("Batch Token Extractor Tests")
struct BatchTokenExtractorTests {
    func createTempSwiftFile(name: String, content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent(name).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func deleteTempFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Batch extractor processes multiple files")
    func multipleFiles() async throws {
        let files = try [
            createTempSwiftFile(name: "a_\(UUID()).swift", content: "let a = 1"),
            createTempSwiftFile(name: "b_\(UUID()).swift", content: "let b = 2"),
            createTempSwiftFile(name: "c_\(UUID()).swift", content: "let c = 3"),
        ]
        defer { files.forEach { deleteTempFile($0) } }

        let extractor = BatchTokenExtractor()
        let result = try await extractor.extract(from: files)

        #expect(result.fileCount == 3)
        #expect(result.totalTokenCount > 0)
    }

    @Test("Parallel extraction works")
    func parallelExtraction() async throws {
        var files: [String] = []
        for i in 0 ..< 5 {
            let file = try createTempSwiftFile(name: "file\(i)_\(UUID()).swift", content: "let x\(i) = \(i)")
            files.append(file)
        }
        defer { files.forEach { deleteTempFile($0) } }

        let extractor = BatchTokenExtractor()
        let result = try await extractor.extractParallel(from: files, maxConcurrency: 4)

        #expect(result.fileCount == 5)
    }
}

// MARK: - SliceBasedTokenSequenceTests

@Suite("Slice-Based Token Sequence Tests")
struct SliceBasedTokenSequenceTests {
    func createTempSwiftFile(content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).swift"
        let path = tempDir.appendingPathComponent(fileName).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func deleteTempFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Slice-based sequence stores token slices")
    func tokenSlices() throws {
        let content = "func test() {}"
        let path = try createTempSwiftFile(content: content)
        defer { deleteTempFile(path) }

        let mmf = try MemoryMappedFile(path: path)
        let tokens = [
            TokenSlice(offset: 0, length: 4, line: 1, column: 1), // func
            TokenSlice(offset: 5, length: 4, line: 1, column: 6), // test
        ]
        let kinds: [UInt8] = [0, 1] // keyword, identifier

        let sequence = SliceBasedTokenSequence(
            file: path,
            source: mmf,
            tokens: tokens,
            kinds: kinds,
        )

        #expect(sequence.count == 2)
        #expect(sequence.text(at: 0) == "func")
        #expect(sequence.text(at: 1) == "test")
    }
}
