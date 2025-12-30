//
//  IgnoreDirectiveTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify swa:ignore directive parsing from source comments
//  - Test directive inheritance (enum cases inherit from parent enum)
//  - Validate different directive formats (line, block, doc comments)
//  - Test specific directive types (ignore, ignore-unused, ignore-unused-cases)
//  - Verify declarations without directives are not affected
//
//  ## Coverage
//  - Basic parsing: swa:ignore, swa:ignore-unused, swa:ignore-unused-cases
//  - Enum case inheritance from parent enum's ignore-unused-cases
//  - Generic swa:ignore marks declaration as ignored
//  - Block comment format (/* swa:ignore */)
//  - Multiple enums with mixed directives
//  - hasIgnoreDirective() method for specific categories
//  - 'all' directive matches any category
//

import SwiftParser
import SwiftStaticAnalysisCore
import SwiftSyntax
import Testing

@Suite("Ignore Directive Tests")
struct IgnoreDirectiveTests {
    // MARK: - Basic Ignore Directive Parsing

    @Test("Enum with ignore directive excludes cases")
    func enumIgnoreDirective() throws {
        let source = """
            /// Description. // swa:ignore-unused-cases
            public enum TestEnum {
                case one
                case two
            }
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let enumCases = collector.declarations.filter { $0.kind == .enumCase }
        #expect(enumCases.count == 2)

        for enumCase in enumCases {
            #expect(enumCase.shouldIgnoreUnused, "Enum case '\(enumCase.name)' should have ignore directive")
        }
    }

    @Test("Enum cases inherit ignore directive from parent enum")
    func enumCasesInheritIgnoreDirective() throws {
        let source = """
            // MARK: - Test

            /// Categories for diagnostics.
            /// Exhaustive coverage. // swa:ignore-unused-cases
            public enum DiagnosticCategory: String {
                case one = "one"
                case two = "two"
            }
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        // Check that enum is found
        let enums = collector.declarations.filter { $0.kind == .enum }
        #expect(enums.count == 1)

        // Check enum's ignore directives
        let enumDecl = enums.first!
        #expect(
            enumDecl.ignoreDirectives.contains("unused_cases"),
            "Enum should have 'unused_cases' ignore directive but has: \(enumDecl.ignoreDirectives)",
        )

        // Check enum cases
        let enumCases = collector.declarations.filter { $0.kind == .enumCase }
        #expect(enumCases.count == 2)

        for enumCase in enumCases {
            #expect(
                enumCase.ignoreDirectives.contains("unused_cases"),
                "Enum case '\(enumCase.name)' should inherit 'unused_cases' directive but has: \(enumCase.ignoreDirectives)",
            )
            #expect(enumCase.shouldIgnoreUnused, "Enum case '\(enumCase.name)' should be ignored for unused")
        }
    }

    // MARK: - Generic swa:ignore Directive

    @Test("Generic swa:ignore directive marks declaration as ignored")
    func genericIgnoreDirective() throws {
        let source = """
            // swa:ignore
            func unusedHelper() {}
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let funcs = collector.declarations.filter { $0.kind == .function }
        #expect(funcs.count == 1)

        let func1 = funcs.first!
        #expect(func1.ignoreDirectives.contains("all"), "Function should have 'all' ignore directive")
        #expect(func1.shouldIgnoreUnused, "Function should be ignored for unused")
    }

    @Test("swa:ignore-unused directive is recognized")
    func ignoreUnusedDirective() throws {
        let source = """
            // swa:ignore-unused
            class UnusedHelper {}
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let classes = collector.declarations.filter { $0.kind == .class }
        #expect(classes.count == 1)

        let cls = classes.first!
        #expect(cls.ignoreDirectives.contains("unused"), "Class should have 'unused' ignore directive")
        #expect(cls.shouldIgnoreUnused, "Class should be ignored for unused")
    }

    // MARK: - Declarations Without Ignore Directives

    @Test("Declarations without ignore directives are not ignored")
    func noIgnoreDirective() throws {
        let source = """
            /// Regular documentation
            public enum RegularEnum {
                case one
                case two
            }

            func regularFunction() {}
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let enumCases = collector.declarations.filter { $0.kind == .enumCase }
        #expect(enumCases.count == 2)

        for enumCase in enumCases {
            #expect(enumCase.ignoreDirectives.isEmpty, "Enum case '\(enumCase.name)' should NOT have ignore directives")
            #expect(!enumCase.shouldIgnoreUnused, "Enum case '\(enumCase.name)' should NOT be ignored")
        }

        let funcs = collector.declarations.filter { $0.kind == .function }
        #expect(funcs.count == 1)
        #expect(!funcs.first!.shouldIgnoreUnused, "Function should NOT be ignored")
    }

    // MARK: - Multiple Enums with Different Directives

    @Test("Multiple enums with mixed ignore directives")
    func mixedIgnoreDirectives() throws {
        let source = """
            /// Ignored enum. // swa:ignore-unused-cases
            enum IgnoredEnum {
                case a
                case b
            }

            /// Not ignored enum.
            enum NotIgnoredEnum {
                case x
                case y
            }
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let allCases = collector.declarations.filter { $0.kind == .enumCase }
        #expect(allCases.count == 4)

        let ignoredCases = allCases.filter { $0.name == "a" || $0.name == "b" }
        let notIgnoredCases = allCases.filter { $0.name == "x" || $0.name == "y" }

        for c in ignoredCases {
            #expect(c.shouldIgnoreUnused, "Case '\(c.name)' from IgnoredEnum should be ignored")
        }

        for c in notIgnoredCases {
            #expect(!c.shouldIgnoreUnused, "Case '\(c.name)' from NotIgnoredEnum should NOT be ignored")
        }
    }

    // MARK: - Comment Format Variations

    @Test("Ignore directive with description after hyphen separator is recognized")
    func ignoreDirectiveWithDescription() throws {
        let source = """
            // swa:ignore-unused - Utility operations for advanced token analysis
            public extension SomeType {
                func countByKind() {}
                func tokensInRange() {}
            }
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let allDecls = collector.declarations.map { "\($0.name):\($0.kind)" }
        let methods = collector.declarations.filter { $0.kind == .method || $0.kind == .function }
        #expect(methods.count == 2, "Expected 2 functions, got \(methods.count). All: \(allDecls)")

        for method in methods {
            #expect(
                method.ignoreDirectives.contains("unused"),
                "Method '\(method.name)' should have 'unused' directive but has: \(method.ignoreDirectives)",
            )
            #expect(method.shouldIgnoreUnused, "Method '\(method.name)' should be ignored for unused")
        }
    }

    @Test("Block comment swa:ignore directive is recognized")
    func blockCommentIgnoreDirective() throws {
        let source = """
            /* swa:ignore */
            func helperFunction() {}
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let funcs = collector.declarations.filter { $0.kind == .function }
        #expect(funcs.count == 1)
        #expect(funcs.first!.shouldIgnoreUnused, "Function with block comment swa:ignore should be ignored")
    }

    // MARK: - Declaration Helper Methods

    @Test("hasIgnoreDirective checks specific categories")
    func hasIgnoreDirectiveMethod() throws {
        let source = """
            // swa:ignore-unused-cases
            enum TestEnum {
                case test
            }
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let enumDecl = collector.declarations.first { $0.kind == .enum }!

        #expect(enumDecl.hasIgnoreDirective(for: "unused_cases"))
        #expect(!enumDecl.hasIgnoreDirective(for: "unused"))
        #expect(!enumDecl.hasIgnoreDirective(for: "all"))
    }

    @Test("hasIgnoreDirective with 'all' matches any category check")
    func hasIgnoreDirectiveAll() throws {
        let source = """
            // swa:ignore
            func test() {}
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let funcDecl = collector.declarations.first { $0.kind == .function }!

        // 'all' should match any category
        #expect(funcDecl.hasIgnoreDirective(for: "unused"))
        #expect(funcDecl.hasIgnoreDirective(for: "unused_cases"))
        #expect(funcDecl.hasIgnoreDirective(for: "anything"))
    }

    // MARK: - Extension Inheritance

    @Test("Functions in extension inherit ignore directive from extension")
    func extensionIgnoreDirectiveInheritance() throws {
        let source = """
            // swa:ignore-unused
            public extension SomeType {
                func method1() {}
                func method2() {}
            }
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        // Debug: check all declarations
        let allDecls = collector.declarations.map { "\($0.name):\($0.kind)" }
        print("All declarations: \(allDecls)")

        // Functions inside extensions should be detected as methods
        let methods = collector.declarations.filter { $0.kind == .method || $0.kind == .function }
        #expect(methods.count == 2, "Expected 2 functions, got \(methods.count). All: \(allDecls)")

        for method in methods {
            #expect(
                method.ignoreDirectives.contains("unused"),
                "Method '\(method.name)' should inherit 'unused' directive from extension but has: \(method.ignoreDirectives)",
            )
            #expect(method.shouldIgnoreUnused, "Method '\(method.name)' should be ignored for unused")
        }
    }

    @Test("Functions in extension with MARK comment inherit ignore directive")
    func extensionWithMarkCommentInheritance() throws {
        let source = """
            // MARK: - Utilities

            // swa:ignore-unused
            public extension SomeType {
                func countByKind() {}
                func tokensInRange() {}
            }
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let allDecls = collector.declarations.map { "\($0.name):\($0.kind)" }
        let methods = collector.declarations.filter { $0.kind == .method || $0.kind == .function }
        #expect(methods.count == 2, "Expected 2 functions, got \(methods.count). All: \(allDecls)")

        for method in methods {
            #expect(
                method.shouldIgnoreUnused,
                "Method '\(method.name)' should be ignored for unused",
            )
        }
    }

    @Test("Nested struct in class inherits ignore directive")
    func nestedStructInheritance() throws {
        let source = """
            // swa:ignore
            class Container {
                struct Nested {
                    var value: Int
                }
                func helper() {}
            }
            """

        let tree = Parser.parse(source: source)
        let collector = DeclarationCollector(file: "test.swift", tree: tree)
        collector.walk(tree)

        let allDecls = collector.declarations.map { "\($0.name):\($0.kind)" }
        print("Nested test declarations: \(allDecls)")

        let structs = collector.declarations.filter { $0.kind == .struct }
        let methods = collector.declarations.filter { $0.kind == .method || $0.kind == .function }
        let variables = collector.declarations.filter { $0.kind == .variable }

        #expect(structs.count == 1, "Expected 1 struct. All: \(allDecls)")
        #expect(methods.count == 1, "Expected 1 method. All: \(allDecls)")
        #expect(variables.count == 1, "Expected 1 variable. All: \(allDecls)")

        if let s = structs.first {
            #expect(s.shouldIgnoreUnused, "Nested struct should inherit ignore from class")
        }
        if let m = methods.first {
            #expect(m.shouldIgnoreUnused, "Method should inherit ignore from class")
        }
        if let v = variables.first {
            #expect(v.shouldIgnoreUnused, "Variable should inherit ignore from struct which inherits from class")
        }
    }
}
