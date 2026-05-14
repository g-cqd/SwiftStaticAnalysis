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

    // MARK: - Security regressions (Phase 1 of AUDIT.md remediation)

    /// Regression test for the CRITICAL sibling-path bypass.
    ///
    /// Before the fix, `hasPrefix(rootPath)` accepted any path whose string
    /// prefix matched the root, so `/tmp/codebase-secret/...` slipped past
    /// the sandbox for a root of `/tmp/codebase`.
    @Test("validatePath rejects sibling directory with shared name prefix")
    func validatePathRejectsSiblingDirectoryBypass() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa-sibling-\(UUID().uuidString)")
        let codebase = parent.appendingPathComponent("codebase")
        let sibling = parent.appendingPathComponent("codebase-secret")

        try FileManager.default.createDirectory(at: codebase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let secret = sibling.appendingPathComponent("secret.txt")
        try "leak".write(to: secret, atomically: true, encoding: .utf8)

        let context = try CodebaseContext(rootPath: codebase.path)

        #expect(throws: CodebaseContextError.self) {
            _ = try context.validatePath(secret.path)
        }
    }

    /// Regression test for the CRITICAL symlink escape.
    ///
    /// A symlink inside the codebase whose target is outside must be rejected
    /// by `validatePath` after `resolvingSymlinksInPath()`.
    @Test("validatePath rejects symlink whose target escapes the sandbox")
    func validatePathRejectsSymlinkEscape() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa-symlink-\(UUID().uuidString)")
        let codebase = parent.appendingPathComponent("codebase")
        let outside = parent.appendingPathComponent("outside")

        try FileManager.default.createDirectory(at: codebase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let target = outside.appendingPathComponent("secret.swift")
        try "// secret".write(to: target, atomically: true, encoding: .utf8)

        let link = codebase.appendingPathComponent("normal.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let context = try CodebaseContext(rootPath: codebase.path)

        #expect(throws: CodebaseContextError.self) {
            _ = try context.validatePath("normal.swift")
        }
    }

    /// Companion regression: `findSwiftFiles` must silently skip symlinks
    /// whose target leaves the sandbox, even when the symlink itself looks
    /// like a regular `.swift` file to the directory enumerator.
    @Test("findSwiftFiles skips symlinks pointing outside the sandbox")
    func findSwiftFilesSkipsEscapingSymlinks() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("swa-find-symlink-\(UUID().uuidString)")
        let codebase = parent.appendingPathComponent("codebase")
        let outside = parent.appendingPathComponent("outside")

        try FileManager.default.createDirectory(at: codebase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let target = outside.appendingPathComponent("secret.swift")
        try "// secret".write(to: target, atomically: true, encoding: .utf8)

        let link = codebase.appendingPathComponent("Sneaky.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let normal = codebase.appendingPathComponent("Normal.swift")
        try "// normal".write(to: normal, atomically: true, encoding: .utf8)

        let context = try CodebaseContext(rootPath: codebase.path)
        let files = try context.findSwiftFiles()

        // Only Normal.swift is allowed through; Sneaky.swift escapes the root.
        #expect(files.count == 1)
        #expect(files.first?.hasSuffix("Normal.swift") == true)
    }

    /// Tilde expansion should not change a path's canonicalisation result.
    @Test("validatePath rejects ~/etc style escapes")
    func validatePathRejectsTildeEscape() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = try CodebaseContext(rootPath: tempDir.path)

        #expect(throws: CodebaseContextError.self) {
            _ = try context.validatePath("~/.ssh/id_rsa")
        }
    }

    /// `matchesGlobPattern` must treat the glob alphabet as glob, not as
    /// regex. Before the fix, regex metacharacters like `+` and `(` leaked
    /// through.
    @Test("matchesGlobPattern escapes regex metacharacters in glob input")
    func matchesGlobPatternEscapesRegexMeta() {
        // `Tests+/file.swift` is a literal directory name containing `+`.
        // A user-supplied glob `Tests+/**` should match it.
        #expect(CodebaseContext.matchesGlobPattern("Tests+/file.swift", pattern: "Tests+/**"))
        // Without escaping, `Tests+` would be regex `Tests+`, which would
        // greedily match `Testss/file.swift` too. After escaping it must not.
        #expect(!CodebaseContext.matchesGlobPattern("Testss/file.swift", pattern: "Tests+/**"))
    }
}
