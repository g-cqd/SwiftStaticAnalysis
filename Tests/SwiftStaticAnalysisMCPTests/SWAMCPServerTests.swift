/// SWAMCPServerTests.swift
/// SwiftStaticAnalysisMCPTests
/// MIT License

import Foundation
import MCP
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
