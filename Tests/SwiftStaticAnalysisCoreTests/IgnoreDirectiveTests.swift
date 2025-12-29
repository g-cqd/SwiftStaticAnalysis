import Testing
import SwiftStaticAnalysisCore
import SwiftParser
import SwiftSyntax

@Suite("Ignore Directive Tests")
struct IgnoreDirectiveTests {
    
    // MARK: - Basic Ignore Directive Parsing
    
    @Test("Enum with ignore directive excludes cases")
    func testEnumIgnoreDirective() throws {
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
    func testEnumCasesInheritIgnoreDirective() throws {
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
        #expect(enumDecl.ignoreDirectives.contains("unused_cases"), "Enum should have 'unused_cases' ignore directive but has: \(enumDecl.ignoreDirectives)")

        // Check enum cases
        let enumCases = collector.declarations.filter { $0.kind == .enumCase }
        #expect(enumCases.count == 2)

        for enumCase in enumCases {
            #expect(enumCase.ignoreDirectives.contains("unused_cases"), "Enum case '\(enumCase.name)' should inherit 'unused_cases' directive but has: \(enumCase.ignoreDirectives)")
            #expect(enumCase.shouldIgnoreUnused, "Enum case '\(enumCase.name)' should be ignored for unused")
        }
    }
    
    // MARK: - Generic swa:ignore Directive
    
    @Test("Generic swa:ignore directive marks declaration as ignored")
    func testGenericIgnoreDirective() throws {
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
    func testIgnoreUnusedDirective() throws {
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
    func testNoIgnoreDirective() throws {
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
    func testMixedIgnoreDirectives() throws {
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
    
    // MARK: - Block Comment Format
    
    @Test("Block comment swa:ignore directive is recognized")
    func testBlockCommentIgnoreDirective() throws {
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
    func testHasIgnoreDirectiveMethod() throws {
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
    func testHasIgnoreDirectiveAll() throws {
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
}
