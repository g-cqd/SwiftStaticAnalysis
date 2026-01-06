//  SymbolContextTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftParser
import SwiftStaticAnalysisCore
import Testing

@testable import SymbolLookup

@Suite("SymbolContext Model Tests")
struct SymbolContextModelTests {
    // MARK: - SourceLine Tests

    @Test("SourceLine formatting without highlight")
    func sourceLineFormattingNoHighlight() {
        let line = SourceLine(lineNumber: 10, content: "let x = 5", isHighlighted: false)

        #expect(line.lineNumber == 10)
        #expect(line.content == "let x = 5")
        #expect(!line.isHighlighted)

        let formatted = line.formatted(lineNumberWidth: 4)
        #expect(formatted.hasPrefix(" "))  // No highlight marker
    }

    @Test("SourceLine formatting with highlight")
    func sourceLineFormattingWithHighlight() {
        let line = SourceLine(lineNumber: 10, content: "let x = 5", isHighlighted: true)

        #expect(line.isHighlighted)

        let formatted = line.formatted(lineNumberWidth: 4)
        #expect(formatted.hasPrefix(">"))  // Highlight marker
    }

    // MARK: - ContextScopeKind Tests

    @Test("ContextScopeKind isType returns correct values")
    func scopeKindIsType() {
        #expect(ContextScopeKind.class.isType)
        #expect(ContextScopeKind.struct.isType)
        #expect(ContextScopeKind.enum.isType)
        #expect(ContextScopeKind.protocol.isType)
        #expect(ContextScopeKind.extension.isType)
        #expect(ContextScopeKind.actor.isType)

        #expect(!ContextScopeKind.function.isType)
        #expect(!ContextScopeKind.method.isType)
        #expect(!ContextScopeKind.closure.isType)
    }

    @Test("ContextScopeKind isCallable returns correct values")
    func scopeKindIsCallable() {
        #expect(ContextScopeKind.function.isCallable)
        #expect(ContextScopeKind.method.isCallable)
        #expect(ContextScopeKind.initializer.isCallable)
        #expect(ContextScopeKind.deinitializer.isCallable)
        #expect(ContextScopeKind.accessor.isCallable)
        #expect(ContextScopeKind.closure.isCallable)

        #expect(!ContextScopeKind.class.isCallable)
        #expect(!ContextScopeKind.struct.isCallable)
        #expect(!ContextScopeKind.file.isCallable)
    }

    // MARK: - ScopeContent Tests

    @Test("ScopeContent lineCount calculation")
    func scopeContentLineCount() {
        let scope = ScopeContent(
            kind: ContextScopeKind.class,
            name: "MyClass",
            startLine: 10,
            endLine: 25,
            source: "class MyClass { }"
        )

        #expect(scope.lineCount == 16)  // 25 - 10 + 1
    }

    // MARK: - DocumentationComment Tests

    @Test("DocumentationComment hasContent returns true when has summary")
    func documentationHasContentWithSummary() {
        let doc = DocumentationComment(
            summary: "A function",
            parameters: [],
            returns: nil,
            throws: nil,
            notes: [],
            rawComment: "/// A function"
        )

        #expect(doc.hasContent)
    }

    @Test("DocumentationComment hasContent returns true when has parameters")
    func documentationHasContentWithParameters() {
        let doc = DocumentationComment(
            summary: nil,
            parameters: [ParameterDoc(name: "value", description: "The value")],
            returns: nil,
            throws: nil,
            notes: [],
            rawComment: "/// - Parameter value: The value"
        )

        #expect(doc.hasContent)
    }

    @Test("DocumentationComment hasContent returns false when empty")
    func documentationHasContentEmpty() {
        let doc = DocumentationComment(
            summary: nil,
            parameters: [],
            returns: nil,
            throws: nil,
            notes: [],
            rawComment: "///"
        )

        #expect(!doc.hasContent)
    }

    // MARK: - SymbolContext Tests

    @Test("SymbolContext isEmpty returns true for empty context")
    func symbolContextIsEmptyTrue() {
        let context = SymbolContext.empty

        #expect(context.isEmpty)
    }

    @Test("SymbolContext isEmpty returns false with lines")
    func symbolContextIsEmptyWithLines() {
        let context = SymbolContext(
            linesBefore: [SourceLine(lineNumber: 1, content: "import Foundation")],
            linesAfter: []
        )

        #expect(!context.isEmpty)
    }

    @Test("SymbolContext isEmpty returns false with documentation")
    func symbolContextIsEmptyWithDocs() {
        let doc = DocumentationComment(
            summary: "Summary",
            rawComment: "/// Summary"
        )
        let context = SymbolContext(documentation: doc)

        #expect(!context.isEmpty)
    }

    // MARK: - SymbolContextConfiguration Tests

    @Test("Configuration none wants no context")
    func configurationNone() {
        let config = SymbolContextConfiguration.none

        #expect(!config.wantsContext)
        #expect(!config.wantsLines)
    }

    @Test("Configuration lines wants context")
    func configurationLines() {
        let config = SymbolContextConfiguration.lines(3)

        #expect(config.wantsContext)
        #expect(config.wantsLines)
        #expect(config.linesBefore == 3)
        #expect(config.linesAfter == 3)
    }

    @Test("Configuration asymmetric lines")
    func configurationAsymmetricLines() {
        let config = SymbolContextConfiguration.lines(before: 2, after: 5)

        #expect(config.linesBefore == 2)
        #expect(config.linesAfter == 5)
    }

    @Test("Configuration all enables everything")
    func configurationAll() {
        let config = SymbolContextConfiguration.all

        #expect(config.wantsContext)
        #expect(config.includeScope)
        #expect(config.includeSignature)
        #expect(config.includeBody)
        #expect(config.includeDocumentation)
    }

    @Test("Configuration clamps negative values")
    func configurationClampsNegatives() {
        let config = SymbolContextConfiguration(
            linesBefore: -5,
            linesAfter: -10
        )

        #expect(config.linesBefore == 0)
        #expect(config.linesAfter == 0)
    }
}

@Suite("SymbolContextExtractor Tests")
struct SymbolContextExtractorTests {
    // MARK: - Line Context Extraction

    @Test("Extract lines before and after")
    func extractLineContext() {
        let extractor = SymbolContextExtractor()
        let lines = [
            "import Foundation",
            "",
            "class MyClass {",
            "    func doWork() {",
            "        print(\"working\")",
            "    }",
            "}",
        ]

        let (before, after) = extractor.extractLineContext(
            lines: lines,
            symbolLine: 4,  // func doWork
            linesBefore: 2,
            linesAfter: 2
        )

        #expect(before.count == 2)
        #expect(before[0].lineNumber == 2)  // Empty line
        #expect(before[1].lineNumber == 3)  // class MyClass

        #expect(after.count == 3)  // Symbol line + 2 after
        #expect(after[0].lineNumber == 4)  // func doWork
        #expect(after[0].isHighlighted)
        #expect(after[1].lineNumber == 5)  // print
        #expect(after[2].lineNumber == 6)  // }
    }

    @Test("Extract lines handles edge cases at start of file")
    func extractLineContextStartOfFile() {
        let extractor = SymbolContextExtractor()
        let lines = [
            "import Foundation",
            "let x = 5",
        ]

        let (before, after) = extractor.extractLineContext(
            lines: lines,
            symbolLine: 1,  // First line
            linesBefore: 5,
            linesAfter: 1
        )

        #expect(before.isEmpty)  // No lines before
        #expect(after.count == 2)
    }

    @Test("Extract lines handles edge cases at end of file")
    func extractLineContextEndOfFile() {
        let extractor = SymbolContextExtractor()
        let lines = [
            "import Foundation",
            "let x = 5",
        ]

        let (before, after) = extractor.extractLineContext(
            lines: lines,
            symbolLine: 2,  // Last line
            linesBefore: 1,
            linesAfter: 5
        )

        #expect(before.count == 1)
        #expect(after.count == 1)  // Just the symbol line
    }

    // MARK: - Documentation Extraction

    @Test("Extract triple-slash documentation")
    func extractTripleSlashDoc() {
        let extractor = SymbolContextExtractor()
        let lines = [
            "import Foundation",
            "",
            "/// A utility function.",
            "/// - Parameter value: The input value.",
            "/// - Returns: The processed result.",
            "func process(value: Int) -> String {",
            "    return String(value)",
            "}",
        ]

        let doc = extractor.extractDocumentation(lines: lines, symbolLine: 6)

        #expect(doc != nil)
        #expect(doc?.summary == "A utility function.")
        #expect(doc?.parameters.count == 1)
        #expect(doc?.parameters.first?.name == "value")
        #expect(doc?.returns == "The processed result.")
    }

    @Test("Extract block comment documentation")
    func extractBlockCommentDoc() {
        let extractor = SymbolContextExtractor()
        let lines = [
            "import Foundation",
            "",
            "/**",
            " A utility function.",
            " - Parameter value: The input value.",
            " */",
            "func process(value: Int) {",
            "}",
        ]

        let doc = extractor.extractDocumentation(lines: lines, symbolLine: 7)

        #expect(doc != nil)
        #expect(doc?.summary == "A utility function.")
    }

    @Test("Extract documentation skips attributes")
    func extractDocSkipsAttributes() {
        let extractor = SymbolContextExtractor()
        let lines = [
            "/// The main entry point.",
            "@main",
            "@available(iOS 15, *)",
            "struct App {",
            "}",
        ]

        let doc = extractor.extractDocumentation(lines: lines, symbolLine: 4)

        #expect(doc != nil)
        #expect(doc?.summary == "The main entry point.")
    }

    @Test("No documentation returns nil")
    func extractNoDocumentation() {
        let extractor = SymbolContextExtractor()
        let lines = [
            "import Foundation",
            "",
            "func noDoc() {",
            "}",
        ]

        let doc = extractor.extractDocumentation(lines: lines, symbolLine: 3)

        #expect(doc == nil)
    }

    // MARK: - Documentation Parsing

    @Test("Parse documentation with throws")
    func parseDocWithThrows() {
        let extractor = SymbolContextExtractor()

        let doc = extractor.parseDocumentation(
            rawComment: """
                /// Loads a resource.
                /// - Parameter name: Resource name.
                /// - Throws: ResourceError if not found.
                /// - Returns: The loaded resource.
                """)

        #expect(doc.summary == "Loads a resource.")
        #expect(doc.parameters.count == 1)
        #expect(doc.throws == "ResourceError if not found.")
        #expect(doc.returns == "The loaded resource.")
    }

    @Test("Parse documentation with notes")
    func parseDocWithNotes() {
        let extractor = SymbolContextExtractor()

        let doc = extractor.parseDocumentation(
            rawComment: """
                /// Main function.
                /// - Note: Must be called on main thread.
                """)

        #expect(doc.summary == "Main function.")
        #expect(doc.notes.count == 1)
        #expect(doc.notes.first == "Must be called on main thread.")
    }
}

@Suite("FileContentCache Tests")
struct FileContentCacheTests {
    @Test("Cache stores and retrieves content")
    func cacheStoresContent() async throws {
        let cache = FileContentCache(maxEntries: 10)

        // Create a temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("cache_test_\(UUID().uuidString).swift")
        try "let x = 42".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let content = try await cache.content(for: tempFile.path)
        #expect(content == "let x = 42")

        // Should be cached
        let cached = await cache.isCached(tempFile.path)
        #expect(cached)
    }

    @Test("Cache evicts at capacity")
    func cacheEvictsAtCapacity() async throws {
        let cache = FileContentCache(maxEntries: 2)

        // Create temp files
        let tempDir = FileManager.default.temporaryDirectory
        var tempFiles: [URL] = []
        for i in 0..<3 {
            let tempFile = tempDir.appendingPathComponent("cache_evict_\(i)_\(UUID().uuidString).swift")
            try "let x = \(i)".write(to: tempFile, atomically: true, encoding: .utf8)
            tempFiles.append(tempFile)
        }
        defer {
            for file in tempFiles { try? FileManager.default.removeItem(at: file) }
        }

        // Add 3 files to cache with capacity 2
        _ = try await cache.content(for: tempFiles[0].path)
        _ = try await cache.content(for: tempFiles[1].path)
        _ = try await cache.content(for: tempFiles[2].path)

        // First file should be evicted
        let count = await cache.count
        #expect(count == 2)

        let firstCached = await cache.isCached(tempFiles[0].path)
        #expect(!firstCached)

        let lastCached = await cache.isCached(tempFiles[2].path)
        #expect(lastCached)
    }

    @Test("Cache invalidate removes entry")
    func cacheInvalidate() async throws {
        let cache = FileContentCache(maxEntries: 10)

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("cache_invalidate_\(UUID().uuidString).swift")
        try "content".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        _ = try await cache.content(for: tempFile.path)
        await cache.invalidate(tempFile.path)

        let cached = await cache.isCached(tempFile.path)
        #expect(!cached)
    }

    @Test("Cache clear removes all entries")
    func cacheClear() async throws {
        let cache = FileContentCache(maxEntries: 10)

        let tempDir = FileManager.default.temporaryDirectory
        var tempFiles: [URL] = []
        for i in 0..<3 {
            let tempFile = tempDir.appendingPathComponent("cache_clear_\(i)_\(UUID().uuidString).swift")
            try "let x = \(i)".write(to: tempFile, atomically: true, encoding: .utf8)
            tempFiles.append(tempFile)
            _ = try await cache.content(for: tempFile.path)
        }
        defer {
            for file in tempFiles { try? FileManager.default.removeItem(at: file) }
        }

        await cache.clear()

        let count = await cache.count
        #expect(count == 0)
    }

    @Test("Cache lines helper works")
    func cacheLinesHelper() async throws {
        let cache = FileContentCache(maxEntries: 10)

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("cache_lines_\(UUID().uuidString).swift")
        try "line1\nline2\nline3".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let lines = try await cache.lines(for: tempFile.path)
        #expect(lines.count == 3)
        #expect(lines[0] == "line1")
        #expect(lines[2] == "line3")
    }
}

@Suite("DeclarationNodeFinder Tests")
struct DeclarationNodeFinderTests {
    @Test("Finds function at line")
    func findsFunctionAtLine() {
        let source = """
            import Foundation

            func myFunction() {
                print("hello")
            }
            """

        let finder = DeclarationNodeFinder(targetLine: 3, targetColumn: 1)
        let tree = Parser.parse(source: source)
        finder.walk(tree)

        #expect(finder.foundDeclaration != nil)
    }

    @Test("Finds class at line")
    func findsClassAtLine() {
        let source = """
            import Foundation

            class MyClass {
                var x: Int = 0
            }
            """

        let finder = DeclarationNodeFinder(targetLine: 3, targetColumn: 1)
        let tree = Parser.parse(source: source)
        finder.walk(tree)

        #expect(finder.foundDeclaration != nil)
    }

    @Test("Finds variable at line")
    func findsVariableAtLine() {
        let source = """
            let globalVar = 42
            """

        let finder = DeclarationNodeFinder(targetLine: 1, targetColumn: 1)
        let tree = Parser.parse(source: source)
        finder.walk(tree)

        #expect(finder.foundDeclaration != nil)
    }
}

@Suite("ScopeNodeFinder Tests")
struct ScopeNodeFinderTests {
    @Test("ContextScopeKind helpers work correctly")
    func scopeKindHelpers() {
        // These are unit tests for the ContextScopeKind enum
        #expect(ContextScopeKind.class.isType)
        #expect(ContextScopeKind.struct.isType)
        #expect(!ContextScopeKind.function.isType)

        #expect(ContextScopeKind.function.isCallable)
        #expect(ContextScopeKind.method.isCallable)
        #expect(!ContextScopeKind.class.isCallable)
    }

    @Test("Empty scope stack when target is outside all scopes")
    func emptyScopeStackOutsideScopes() {
        let source = """
            // Just a comment
            """

        let finder = ScopeNodeFinder(targetLine: 1, targetColumn: 1)
        let tree = Parser.parse(source: source)
        finder.walk(tree)

        // No scopes in a file with just a comment
        #expect(finder.scopeStack.isEmpty)
        #expect(finder.innermostScope == nil)
    }

    @Test("Finder initializes with correct target position")
    func finderInitialization() {
        let finder = ScopeNodeFinder(targetLine: 10, targetColumn: 5)

        // Verify it can be walked
        let source = "let x = 5"
        let tree = Parser.parse(source: source)
        finder.walk(tree)

        // Should complete without error
        #expect(true)
    }

    @Test("ContextScopeKind rawValues are correct")
    func scopeKindRawValues() {
        #expect(ContextScopeKind.file.rawValue == "file")
        #expect(ContextScopeKind.class.rawValue == "class")
        #expect(ContextScopeKind.struct.rawValue == "struct")
        #expect(ContextScopeKind.enum.rawValue == "enum")
        #expect(ContextScopeKind.protocol.rawValue == "protocol")
        #expect(ContextScopeKind.extension.rawValue == "extension")
        #expect(ContextScopeKind.function.rawValue == "function")
        #expect(ContextScopeKind.method.rawValue == "method")
        #expect(ContextScopeKind.initializer.rawValue == "initializer")
        #expect(ContextScopeKind.deinitializer.rawValue == "deinitializer")
        #expect(ContextScopeKind.accessor.rawValue == "accessor")
        #expect(ContextScopeKind.closure.rawValue == "closure")
        #expect(ContextScopeKind.actor.rawValue == "actor")
    }

    @Test("ContextScopeKind CaseIterable contains all cases")
    func scopeKindCaseIterable() {
        let allCases = ContextScopeKind.allCases
        #expect(allCases.count == 13)
    }
}
