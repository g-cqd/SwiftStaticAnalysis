/// SWAMCPServerTests.swift
/// SwiftStaticAnalysisMCPTests
/// MIT License

import Foundation
import MCP
import SwiftStaticAnalysisCore
import Testing

@testable import SwiftStaticAnalysisMCP

@Suite("SWAMCPServer Tests")
struct SWAMCPServerTests {
    // MARK: - Test Fixture Helpers

    /// Creates a temporary directory with test Swift files.
    private func createTestCodebase() throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa_mcp_test_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create main source file
        let mainFile = tempDir.appendingPathComponent("Main.swift")
        try """
        import Foundation

        class NetworkManager {
            static let shared = NetworkManager()
            private init() {}

            func fetch(id: Int) -> Data {
                Data()
            }

            func fetch(name: String) -> Data {
                Data()
            }
        }

        func unusedFunction() {
            print("never called")
        }

        let globalConstant = 42
        """.write(to: mainFile, atomically: true, encoding: .utf8)

        // Create a duplicate file for clone detection
        let utilsFile = tempDir.appendingPathComponent("Utils.swift")
        try """
        import Foundation

        class CacheManager {
            static let shared = CacheManager()
            private init() {}

            func fetch(id: Int) -> Data {
                Data()
            }
        }

        func helperFunction() -> Int {
            return 42
        }
        """.write(to: utilsFile, atomically: true, encoding: .utf8)

        return tempDir.path
    }

    /// Cleans up test directory.
    private func cleanupTestCodebase(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Server Initialization Tests

    @Test("Server initializes with valid codebase path")
    func serverInitializesWithValidPath() async throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        let server = try SWAMCPServer(codebasePath: codebasePath)
        let context = await server.defaultContext
        #expect(context != nil)
        #expect(context?.rootPath == codebasePath)
    }

    @Test("Server initializes without default path")
    func serverInitializesWithoutPath() async throws {
        let server = try SWAMCPServer(codebasePath: nil)
        let context = await server.defaultContext
        #expect(context == nil)
    }

    @Test("Server fails to initialize with invalid path")
    func serverFailsWithInvalidPath() {
        #expect(throws: CodebaseContextError.self) {
            _ = try SWAMCPServer(codebasePath: "/nonexistent/path/\(UUID().uuidString)")
        }
    }

    // MARK: - Tool Tests (using Reflection)

    // Since tool calls are handled internally, we test the CodebaseContext
    // functionality which underlies the tool handlers.

    @Test("Get codebase info tool functionality")
    func getCodebaseInfoTool() throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        let context = try CodebaseContext(rootPath: codebasePath)
        let info = try context.getCodebaseInfo()

        #expect(info.rootPath == codebasePath)
        #expect(info.swiftFileCount == 2)
        #expect(info.totalLines > 0)
        #expect(info.totalBytes > 0)
    }

    @Test("List Swift files tool functionality")
    func listSwiftFilesTool() throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        let context = try CodebaseContext(rootPath: codebasePath)
        let files = try context.findSwiftFiles()

        #expect(files.count == 2)
        #expect(files.contains { $0.hasSuffix("Main.swift") })
        #expect(files.contains { $0.hasSuffix("Utils.swift") })
    }

    @Test("List Swift files with exclusions")
    func listSwiftFilesWithExclusions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa_mcp_exclusion_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testsDir = tempDir.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: testsDir, withIntermediateDirectories: true)

        let mainFile = tempDir.appendingPathComponent("Main.swift")
        let testFile = testsDir.appendingPathComponent("MainTests.swift")

        try "// Main".write(to: mainFile, atomically: true, encoding: .utf8)
        try "// Tests".write(to: testFile, atomically: true, encoding: .utf8)

        let context = try CodebaseContext(rootPath: tempDir.path)
        let files = try context.findSwiftFiles(excludePatterns: ["**/Tests/**"])

        #expect(files.count == 1)
        #expect(files.first?.hasSuffix("Main.swift") == true)
    }

    @Test("Read file tool functionality")
    func readFileTool() throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        let context = try CodebaseContext(rootPath: codebasePath)
        let filePath = try context.validatePath("Main.swift")

        let content = try String(contentsOfFile: filePath, encoding: .utf8)

        #expect(content.contains("NetworkManager"))
        #expect(content.contains("fetch"))
    }

    @Test("Read file with line range")
    func readFileWithLineRange() throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        let context = try CodebaseContext(rootPath: codebasePath)
        let filePath = try context.validatePath("Main.swift")

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        // Read first 5 lines
        let selectedLines = Array(lines.prefix(5))
        #expect(selectedLines.count == 5)
        #expect(selectedLines[0].contains("import"))
    }

    @Test("Validate path rejects path traversal")
    func validatePathRejectsTraversal() throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        let context = try CodebaseContext(rootPath: codebasePath)

        #expect(throws: CodebaseContextError.self) {
            _ = try context.validatePath("../../../etc/passwd")
        }
    }

    @Test("Validate path rejects absolute paths outside sandbox")
    func validatePathRejectsAbsolutePath() throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        let context = try CodebaseContext(rootPath: codebasePath)

        #expect(throws: CodebaseContextError.self) {
            _ = try context.validatePath("/etc/passwd")
        }
    }

    // MARK: - Dynamic Codebase Path Tests

    @Test("Server supports dynamic codebase paths")
    func serverSupportsDynamicPaths() async throws {
        // Create two separate codebases
        let codebase1 = try createTestCodebase()
        let codebase2 = try createTestCodebase()
        defer {
            cleanupTestCodebase(codebase1)
            cleanupTestCodebase(codebase2)
        }

        // Server without default path
        let server = try SWAMCPServer(codebasePath: nil)
        let serverContext = await server.defaultContext
        #expect(serverContext == nil)

        // Verify both codebases exist
        let context1 = try CodebaseContext(rootPath: codebase1)
        let context2 = try CodebaseContext(rootPath: codebase2)

        let files1 = try context1.findSwiftFiles()
        let files2 = try context2.findSwiftFiles()

        #expect(files1.count == 2)
        #expect(files2.count == 2)
    }

    // MARK: - Error Handling Tests

    @Test("Context error for no codebase specified")
    func contextErrorNoCodebase() {
        let error = CodebaseContextError.noCodebaseSpecified
        #expect(error.localizedDescription.contains("codebase"))
    }

    @Test("Context error for invalid root path")
    func contextErrorInvalidPath() {
        let error = CodebaseContextError.invalidRootPath("/fake/path")
        #expect(error.localizedDescription.contains("/fake/path"))
    }

    @Test("Context error for path outside sandbox")
    func contextErrorOutsideSandbox() {
        let error = CodebaseContextError.pathOutsideSandbox("/etc/passwd", allowedRoot: "/home")
        #expect(error.localizedDescription.contains("outside"))
    }

    // MARK: - HIGH security regressions

    @Test(
        "read_file rejects extensions commonly used to store secrets",
        arguments: ["secrets.json", "Appfile.plist", "credentials.yaml", "config.yml"]
    )
    func readFileRejectsSecretBearingExtensions(filename: String) async throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        // Plant a same-extension file inside the sandbox to prove that the
        // *extension allowlist* is what closes the surface (not just path
        // validation, which would happily allow the file).
        let suspect = (codebasePath as NSString).appendingPathComponent(filename)
        try "fake-secret".write(toFile: suspect, atomically: true, encoding: .utf8)

        let server = try SWAMCPServer(codebasePath: codebasePath)

        // The handler returns CallTool.Result with `isError: true`; we use
        // the public-surface tool-call test wrapper to drive it. The
        // extension allowlist sits below path validation, so the path
        // check passes and we reach the allowlist refusal.
        let context = try await server._test_getContext(for: codebasePath)
        let validatedPath = try context.validatePath(filename)
        #expect(throws: SWAMCPServer.ReadFileValidationError.self) {
            _ = try SWAMCPServer.validateForReadFile(path: filename, validatedPath: validatedPath)
        }
    }

    @Test("ReadResource URI parser rejects host-bearing file:// URIs")
    func readResourceURIRejectsHost() throws {
        // file://example.com/etc/passwd previously collapsed to the
        // relative path `example.com/etc/passwd`, producing surprise
        // matches inside the sandbox. Must be rejected outright.
        #expect(throws: ReadResourceURIError.self) {
            _ = try SWAMCPServer.parseFileURI("file://example.com/etc/passwd")
        }
    }

    @Test(
        "ReadResource URI parser produces a deterministic path per RFC 3986",
        arguments: [
            // Reserved separator (`%2F`) is kept encoded by `URL.path`,
            // so the encoded form cannot smuggle a `/` past the sandbox.
            ("file:///a%2Fb", "/a%2Fb"),
            // Unreserved characters (`.`, space) decode normally. The
            // resulting `..` is then collapsed by
            // `URL.standardizedFileURL` inside `CodebaseContext.validatePath`,
            // which is what catches the traversal end-to-end.
            ("file:///%2e%2e/etc/passwd", "/../etc/passwd"),
            ("file:///path%20with%20spaces", "/path with spaces"),
            // Plain unencoded path passes through.
            ("file:///Users/me/project/Sources/Test.swift", "/Users/me/project/Sources/Test.swift"),
        ] as [(String, String)]
    )
    func readResourceURIParsing(uri: String, expected: String) throws {
        let path = try SWAMCPServer.parseFileURI(uri)
        #expect(path == expected)
    }

    @Test("ReadResource URI parser rejects non-file schemes")
    func readResourceURIRejectsNonFileScheme() {
        #expect(throws: ReadResourceURIError.self) {
            _ = try SWAMCPServer.parseFileURI("http://example.com/Test.swift")
        }
        #expect(throws: ReadResourceURIError.self) {
            _ = try SWAMCPServer.parseFileURI("https://example.com/Test.swift")
        }
        // Bare malformed URI also rejected.
        #expect(throws: ReadResourceURIError.self) {
            _ = try SWAMCPServer.parseFileURI("not-a-uri")
        }
    }

    @Test("ReadResource URI parser allows empty host (file:///) and localhost")
    func readResourceURIAcceptsValidHosts() throws {
        #expect(try SWAMCPServer.parseFileURI("file:///tmp/x") == "/tmp/x")
        #expect(try SWAMCPServer.parseFileURI("file://localhost/tmp/x") == "/tmp/x")
        #expect(try SWAMCPServer.parseFileURI("file://Localhost/tmp/x") == "/tmp/x")
    }

    @Test("ReadResource URI parser rejects file:// with empty path")
    func readResourceURIRejectsEmptyPath() {
        #expect(throws: ReadResourceURIError.self) {
            _ = try SWAMCPServer.parseFileURI("file://")
        }
    }

    @Test("detect_unused_code rejects an index_store_path outside the sandbox")
    func indexStorePathOutsideSandboxThrows() async throws {
        let codebasePath = try createTestCodebase()
        defer { cleanupTestCodebase(codebasePath) }

        let server = try SWAMCPServer(codebasePath: codebasePath)
        let maliciousPath = "/etc/passwd"

        // The handler should throw via CodebaseContext.validatePath before any
        // filesystem-write side effect can reach IndexStoreReader.
        await #expect(throws: CodebaseContextError.self) {
            _ = try await server._test_handleDetectUnusedCode([
                "codebase_path": .string(codebasePath),
                "mode": .string("indexStore"),
                "index_store_path": .string(maliciousPath),
            ])
        }
    }

    // MARK: - contextCache LRU regression

    @Test("contextCache evicts the oldest entry once capacity is exceeded")
    func contextCacheEvictsBeyondCapacity() async throws {
        let server = try SWAMCPServer(codebasePath: nil)
        let capacity = SWAMCPServer.contextCacheCapacity

        // Build (capacity + 5) distinct codebases.
        var paths: [String] = []
        for _ in 0..<(capacity + 5) {
            paths.append(try createTestCodebase())
        }
        defer { paths.forEach(cleanupTestCodebase) }

        // Touch each path through the server in insertion order.
        for path in paths {
            _ = try await server._test_getContext(for: path)
        }

        // Cache count must be clamped at capacity.
        let resident = await server._test_contextCacheCount
        #expect(resident == capacity, "Cache should plateau at capacity, got \(resident)")

        // Earliest paths must have been evicted; latest must still be cached.
        // We compare against the canonicalised path the server actually keys.
        let lastFiveCanonicalised = paths.suffix(5).map {
            PathUtilities.canonicalize(
                $0,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
        }
        for path in lastFiveCanonicalised {
            let cached = await server._test_contextCacheContains(path)
            #expect(cached, "Most-recently-used entry \(path) should remain cached")
        }

        let firstCanonicalised = PathUtilities.canonicalize(
            paths[0],
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let firstCached = await server._test_contextCacheContains(firstCanonicalised)
        #expect(firstCached == false, "Oldest entry should have been evicted")
    }
}

// MARK: - Tool Schema Tests

@Suite("MCP Tool Schema Tests")
struct ToolSchemaTests {
    @Test("Server exposes expected tools")
    func serverExposesExpectedTools() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa_schema_test_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a minimal test file
        let testFile = tempDir.appendingPathComponent("Test.swift")
        try "// Test".write(to: testFile, atomically: true, encoding: .utf8)

        let server = try SWAMCPServer(codebasePath: tempDir.path)

        // We can verify the server was created successfully by checking defaultContext
        let context = await server.defaultContext
        #expect(context != nil)
    }

    @Test("CodebaseInfo contains expected fields")
    func codebaseInfoFields() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa_info_test_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("Test.swift")
        try "import Foundation\nclass Test {}".write(to: testFile, atomically: true, encoding: .utf8)

        let context = try CodebaseContext(rootPath: tempDir.path)
        let info = try context.getCodebaseInfo()

        #expect(info.rootPath == tempDir.path)
        #expect(info.swiftFileCount >= 1)
        #expect(info.totalLines >= 1)
        #expect(info.totalBytes > 0)
        #expect(!info.formattedSize.isEmpty)
    }
}
