//  SyntaxResolverTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore
import SymbolLookup
import Testing

@Suite("SyntaxResolver Tests")
struct SyntaxResolverTests {
    // MARK: - Test Fixtures

    /// Creates a temporary Swift file with the given content.
    private func createTempFile(content: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).swift"
        let filePath = tempDir.appendingPathComponent(fileName).path

        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    /// Cleans up a temporary file.
    private func cleanupFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Simple Name Resolution

    @Test("Resolves simple function name")
    func resolveSimpleFunctionName() async throws {
        let code = """
            func myFunction() {
                print("Hello")
            }

            func anotherFunction() {
                myFunction()
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("myFunction"), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].name == "myFunction")
        #expect(matches[0].kind == .function)
    }

    @Test("Resolves multiple declarations with same name")
    func resolveMultipleDeclarations() async throws {
        let code = """
            class Container1 {
                func process() {}
            }

            class Container2 {
                func process() {}
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("process"), in: [file])

        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.name == "process" })
        // Note: The analyzer returns .function for methods, not .method
        #expect(matches.allSatisfy { $0.kind == .function || $0.kind == .method })
    }

    @Test("Returns empty for non-existent symbol")
    func resolveNonExistent() async throws {
        let code = """
            func foo() {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("bar"), in: [file])

        #expect(matches.isEmpty)
    }

    // MARK: - Qualified Name Resolution

    @Test("Resolves qualified name Type.member")
    func resolveQualifiedName() async throws {
        let code = """
            class MyClass {
                func myMethod() {}
            }

            struct OtherType {
                func myMethod() {}
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.qualifiedName(["MyClass", "myMethod"]), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].name == "myMethod")
        #expect(matches[0].containingType == "MyClass")
    }

    @Test("Resolves single-component qualified name as simple name")
    func resolveSingleComponentQualified() async throws {
        let code = """
            func standalone() {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.qualifiedName(["standalone"]), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].name == "standalone")
    }

    // MARK: - Regex Resolution

    @Test("Resolves symbols matching regex pattern")
    func resolveByRegex() async throws {
        let code = """
            func fetchUser() {}
            func fetchData() {}
            func processData() {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.regex("fetch.*"), in: [file])

        #expect(matches.count == 2)
        #expect(matches.contains { $0.name == "fetchUser" })
        #expect(matches.contains { $0.name == "fetchData" })
        #expect(!matches.contains { $0.name == "processData" })
    }

    @Test("Regex with no matches returns empty")
    func regexNoMatches() async throws {
        let code = """
            func foo() {}
            func bar() {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.regex("^xyz.*"), in: [file])

        #expect(matches.isEmpty)
    }

    // MARK: - Selector Resolution

    @Test("Resolves selector with labels")
    func resolveSelectorWithLabels() async throws {
        let code = """
            class API {
                func fetch(id: Int) -> Data { Data() }
                func fetch(name: String) -> Data { Data() }
                func fetch() -> Data { Data() }
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.selector(name: "fetch", labels: ["id"]), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].name == "fetch")
        #expect(matches[0].signature?.parameters.count == 1)
        #expect(matches[0].signature?.parameters[0].label == "id")
    }

    @Test("Resolves selector with unlabeled parameter")
    func resolveSelectorUnlabeled() async throws {
        let code = """
            func process(_ value: Int) {}
            func process(value: Int) {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.selector(name: "process", labels: [nil]), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].signature?.parameters[0].label == nil)
    }

    @Test("Resolves selector with no parameters")
    func resolveSelectorNoParams() async throws {
        let code = """
            class Thing {
                func run() {}
                func run(fast: Bool) {}
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.selector(name: "run", labels: []), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].signature?.parameters.isEmpty == true)
    }

    // MARK: - Qualified Selector Resolution

    @Test("Resolves qualified selector")
    func resolveQualifiedSelector() async throws {
        let code = """
            class NetworkManager {
                func fetch(id: Int) {}
            }

            class CacheManager {
                func fetch(id: Int) {}
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(
            .qualifiedSelector(types: ["NetworkManager"], name: "fetch", labels: ["id"]),
            in: [file]
        )

        #expect(matches.count == 1)
        #expect(matches[0].containingType == "NetworkManager")
    }

    // MARK: - USR Resolution

    @Test("USR resolution returns empty for syntax resolver")
    func usrReturnsEmpty() async throws {
        let code = """
            func test() {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.usr("s:4test4testyyF"), in: [file])

        #expect(matches.isEmpty)  // USR not supported in syntax mode
    }

    // MARK: - Reference Finding

    @Test("Finds references to symbol")
    func findReferences() async throws {
        let code = """
            func helper() {}

            func main() {
                helper()
                helper()
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("helper"), in: [file])
        #expect(matches.count == 1)

        let references = try await resolver.findReferences(to: matches[0], in: [file])

        // Should find references (calls) to helper
        #expect(references.count >= 2)
        #expect(references.allSatisfy { $0.kind == .call })
    }

    // MARK: - Multiple Files

    @Test("Resolves across multiple files")
    func resolveAcrossFiles() async throws {
        let code1 = """
            func sharedFunction() {}
            """

        let code2 = """
            class Container {
                func sharedFunction() {}
            }
            """

        let file1 = try createTempFile(content: code1)
        let file2 = try createTempFile(content: code2)
        defer {
            cleanupFile(file1)
            cleanupFile(file2)
        }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("sharedFunction"), in: [file1, file2])

        #expect(matches.count == 2)
    }

    // MARK: - Symbol Types

    @Test("Resolves class declarations")
    func resolveClass() async throws {
        let code = """
            class MyClass {
                var property: Int = 0
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("MyClass"), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].kind == .class)
    }

    @Test("Resolves struct declarations")
    func resolveStruct() async throws {
        let code = """
            struct Point {
                var x: Double
                var y: Double
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("Point"), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].kind == .struct)
    }

    @Test("Resolves enum declarations")
    func resolveEnum() async throws {
        let code = """
            enum Direction {
                case north, south, east, west
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("Direction"), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].kind == .enum)
    }

    @Test("Resolves protocol declarations")
    func resolveProtocol() async throws {
        let code = """
            protocol Drawable {
                func draw()
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("Drawable"), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].kind == .protocol)
    }

    @Test("Resolves variable declarations")
    func resolveVariable() async throws {
        let code = """
            var globalVariable = 42
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("globalVariable"), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].kind == .variable)
    }

    @Test("Resolves constant declarations")
    func resolveConstant() async throws {
        let code = """
            let globalConstant = "test"
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("globalConstant"), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].kind == .constant)
    }

    // MARK: - Access Levels

    @Test("Captures access level")
    func capturesAccessLevel() async throws {
        let code = """
            public func publicFunc() {}
            internal func internalFunc() {}
            private func privateFunc() {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()

        let publicMatches = try await resolver.resolve(.simpleName("publicFunc"), in: [file])
        #expect(publicMatches[0].accessLevel == .public)

        let internalMatches = try await resolver.resolve(.simpleName("internalFunc"), in: [file])
        #expect(internalMatches[0].accessLevel == .internal)

        let privateMatches = try await resolver.resolve(.simpleName("privateFunc"), in: [file])
        #expect(privateMatches[0].accessLevel == .private)
    }

    // MARK: - Static Members

    @Test("Detects static members")
    func detectsStaticMembers() async throws {
        let code = """
            class Container {
                static func staticMethod() {}
                func instanceMethod() {}
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()

        let staticMatches = try await resolver.resolve(.simpleName("staticMethod"), in: [file])
        #expect(staticMatches[0].isStatic == true)

        let instanceMatches = try await resolver.resolve(.simpleName("instanceMethod"), in: [file])
        #expect(instanceMatches[0].isStatic == false)
    }

    // MARK: - Generic Parameters

    @Test("Captures generic parameters")
    func capturesGenericParameters() async throws {
        let code = """
            func transform<T, U>(value: T, using: (T) -> U) -> U {
                using(value)
            }
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("transform"), in: [file])

        #expect(matches.count == 1)
        #expect(matches[0].genericParameters == ["T", "U"])
    }

    // MARK: - Default Files

    @Test("Resolver with default files")
    func resolverWithDefaultFiles() async throws {
        let code = """
            func defaultFileFunc() {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver(defaultFiles: [file])
        let matches = try await resolver.resolve(.simpleName("defaultFileFunc"))

        #expect(matches.count == 1)
    }

    // MARK: - Edge Cases

    @Test("Empty file returns no matches")
    func emptyFile() async throws {
        let code = ""

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("anything"), in: [file])

        #expect(matches.isEmpty)
    }

    @Test("Empty files array returns no matches")
    func emptyFilesArray() async throws {
        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.simpleName("anything"), in: [])

        #expect(matches.isEmpty)
    }

    @Test("Empty qualified name returns no matches")
    func emptyQualifiedName() async throws {
        let code = """
            func foo() {}
            """

        let file = try createTempFile(content: code)
        defer { cleanupFile(file) }

        let resolver = SyntaxResolver()
        let matches = try await resolver.resolve(.qualifiedName([]), in: [file])

        #expect(matches.isEmpty)
    }
}
