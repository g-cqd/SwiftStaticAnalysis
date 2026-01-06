/// CodebaseContextTests.swift
/// SwiftStaticAnalysisMCPTests
/// MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisMCP

@Suite("CodebaseContext Tests")
struct CodebaseContextTests {
    @Test("Initialize with valid path")
    func initWithValidPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try CodebaseContext(rootPath: tempDir.path)
        #expect(context.rootPath == tempDir.path)
    }

    @Test("Initialize with invalid path throws error")
    func initWithInvalidPath() {
        #expect(throws: CodebaseContextError.self) {
            _ = try CodebaseContext(rootPath: "/nonexistent/path/\(UUID().uuidString)")
        }
    }

    @Test("Validate path within sandbox")
    func validatePathWithinSandbox() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try CodebaseContext(rootPath: tempDir.path)

        // Relative path should work
        let validated = try context.validatePath("subdir/file.swift")
        #expect(validated.hasPrefix(tempDir.path))
    }

    @Test("Validate path outside sandbox throws error")
    func validatePathOutsideSandbox() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try CodebaseContext(rootPath: tempDir.path)

        #expect(throws: CodebaseContextError.self) {
            _ = try context.validatePath("/etc/passwd")
        }
    }

    @Test("Validate path traversal attack is blocked")
    func validatePathTraversalBlocked() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try CodebaseContext(rootPath: tempDir.path)

        #expect(throws: CodebaseContextError.self) {
            _ = try context.validatePath("../../../etc/passwd")
        }
    }

    @Test("Find Swift files")
    func findSwiftFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create some test files
        let swiftFile1 = tempDir.appendingPathComponent("Test1.swift")
        let swiftFile2 = tempDir.appendingPathComponent("Test2.swift")
        let otherFile = tempDir.appendingPathComponent("Other.txt")

        try "// Test".write(to: swiftFile1, atomically: true, encoding: .utf8)
        try "// Test".write(to: swiftFile2, atomically: true, encoding: .utf8)
        try "Other".write(to: otherFile, atomically: true, encoding: .utf8)

        let context = try CodebaseContext(rootPath: tempDir.path)
        let swiftFiles = try context.findSwiftFiles()

        #expect(swiftFiles.count == 2)
        #expect(swiftFiles.allSatisfy { $0.hasSuffix(".swift") })
    }

    @Test("Find Swift files with exclusions")
    func findSwiftFilesWithExclusions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        let testsDir = tempDir.appendingPathComponent("Tests")

        try FileManager.default.createDirectory(at: testsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create files
        let mainFile = tempDir.appendingPathComponent("Main.swift")
        let testFile = testsDir.appendingPathComponent("Test.swift")

        try "// Main".write(to: mainFile, atomically: true, encoding: .utf8)
        try "// Test".write(to: testFile, atomically: true, encoding: .utf8)

        let context = try CodebaseContext(rootPath: tempDir.path)
        let swiftFiles = try context.findSwiftFiles(excludePatterns: ["**/Tests/**"])

        #expect(swiftFiles.count == 1)
        #expect(swiftFiles.first?.hasSuffix("Main.swift") == true)
    }

    @Test("Get codebase info")
    func getCodebaseInfo() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a test file with some content
        let content = """
            import Foundation

            struct Test {
                var value: Int
            }
            """
        let swiftFile = tempDir.appendingPathComponent("Test.swift")
        try content.write(to: swiftFile, atomically: true, encoding: .utf8)

        let context = try CodebaseContext(rootPath: tempDir.path)
        let info = try context.getCodebaseInfo()

        #expect(info.swiftFileCount == 1)
        #expect(info.totalLines >= 5)  // Line count depends on trailing newline
        #expect(info.totalBytes > 0)
    }
}
