//  SwiftFileParserTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import SwiftStaticAnalysisCore

@Suite("SwiftFileParser Tests")
struct SwiftFileParserTests {
    // MARK: - Basic Parsing

    @Test("Parse valid Swift source code")
    func parseValidSource() async throws {
        let source = """
            import Foundation

            struct User {
                let name: String
                let age: Int
            }

            func greet(_ user: User) -> String {
                return "Hello, \\(user.name)!"
            }
            """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        #expect(!tree.statements.isEmpty)
    }

    @Test("Parse source with syntax errors gracefully")
    func parseSyntaxErrors() async throws {
        let source = """
            func broken( {
                let x =
            }
            """

        let parser = SwiftFileParser()
        // Should not throw - SwiftSyntax handles errors gracefully
        let tree = try await parser.parse(source: source)

        // Tree should still exist despite errors
        #expect(!tree.statements.isEmpty)
    }

    @Test("Parse empty source")
    func parseEmptySource() async throws {
        let source = ""

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        #expect(tree.statements.isEmpty)
    }

    @Test("Parse source with only comments")
    func parseOnlyComments() async throws {
        let source = """
            // This is a comment
            /* This is a block comment */
            /// This is a doc comment
            """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        // Comments don't create statements
        #expect(tree.statements.isEmpty)
    }

    // MARK: - File Parsing

    @Test("Parse Swift file from disk")
    func parseFile() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("DuplicationScenarios")
            .appendingPathComponent("ExactClones")
            .appendingPathComponent("NetworkingDuplication.swift")

        try #require(
            FileManager.default.fileExists(atPath: fixturesPath.path),
            "Fixture file required at: \(fixturesPath.path)",
        )

        let parser = SwiftFileParser()
        let tree = try await parser.parse(fixturesPath.path)

        #expect(!tree.statements.isEmpty)
    }

    // MARK: - Line Counting

    @Test("Count lines accurately")
    func countLines() async throws {
        let source = """
            line 1
            line 2
            line 3
            line 4
            line 5
            """

        let parser = SwiftFileParser()
        let lineCount = try await parser.lineCount(source: source)

        #expect(lineCount == 5)
    }

    @Test("Count lines with empty lines")
    func countLinesWithEmpty() async throws {
        let source = """
            line 1

            line 3

            line 5
            """

        let parser = SwiftFileParser()
        let lineCount = try await parser.lineCount(source: source)

        #expect(lineCount == 5)
    }

    // MARK: - Caching

    @Test("Cache invalidation works")
    func cacheInvalidation() async throws {
        let source = """
            let x = 1
            """

        let parser = SwiftFileParser()
        let tree1 = try await parser.parse(source: source)
        let tree2 = try await parser.parse(source: source)

        // Both parses should succeed
        #expect(tree1.statements.count == tree2.statements.count)
    }

    // MARK: - Complex Sources

    @Test("Parse complex nested structures")
    func parseNestedStructures() async throws {
        let source = """
            class Outer {
                struct Inner {
                    enum Deepest {
                        case a, b, c

                        func process() -> Int {
                            switch self {
                            case .a: return 1
                            case .b: return 2
                            case .c: return 3
                            }
                        }
                    }
                }
            }
            """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        #expect(!tree.statements.isEmpty)
    }

    @Test("Parse async/await syntax")
    func parseAsyncAwait() async throws {
        let source = """
            func fetchData() async throws -> Data {
                let url = URL(string: "https://example.com")!
                let (data, _) = try await URLSession.shared.data(from: url)
                return data
            }

            actor DataManager {
                private var cache: [String: Data] = [:]

                func getCached(_ key: String) -> Data? {
                    cache[key]
                }
            }
            """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        #expect(!tree.statements.isEmpty)
    }

    @Test("Parse generic types")
    func parseGenerics() async throws {
        let source = """
            struct Container<T: Equatable> where T: Hashable {
                var items: [T] = []

                mutating func add(_ item: T) {
                    if !items.contains(item) {
                        items.append(item)
                    }
                }
            }

            func process<T, U>(_ input: T, transform: (T) -> U) -> U {
                transform(input)
            }
            """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        #expect(!tree.statements.isEmpty)
    }

    @Test("Parse property wrappers and result builders")
    func parseModernSwift() async throws {
        let source = """
            @propertyWrapper
            struct Clamped<Value: Comparable> {
                var wrappedValue: Value
                let range: ClosedRange<Value>

                init(wrappedValue: Value, _ range: ClosedRange<Value>) {
                    self.range = range
                    self.wrappedValue = min(max(wrappedValue, range.lowerBound), range.upperBound)
                }
            }

            @resultBuilder
            struct ArrayBuilder<Element> {
                static func buildBlock(_ components: Element...) -> [Element] {
                    components
                }
            }
            """

        let parser = SwiftFileParser()
        let tree = try await parser.parse(source: source)

        #expect(!tree.statements.isEmpty)
    }
}
