//  SwiftSyntaxModeTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import SwiftStaticAnalysisCore
@testable import UnusedCodeDetector

// MARK: - SwiftSyntaxModeTests

@Suite("SwiftSyntax Mode Unused Code Tests")
struct SwiftSyntaxModeTests {
    // MARK: - Basic Detection

    @Test("Detect unused private functions")
    func detectUnusedPrivateFunctions() async throws {
        let source = """
            private func usedFunction() {
                print("used")
            }

            private func unusedFunction() {
                print("unused")
            }

            func main() {
                usedFunction()
            }
            """

        let detector = UnusedCodeDetector(configuration: .default)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // unusedFunction should be detected as unused
        let unusedFuncs = result.filter { $0.declaration.name == "unusedFunction" }
        #expect(unusedFuncs.count >= 1)

        // usedFunction should NOT be detected as unused
        let usedFuncs = result.filter { $0.declaration.name == "usedFunction" }
        #expect(usedFuncs.isEmpty)
    }

    @Test("Detect unused variables")
    func detectUnusedVariables() async throws {
        let source = """
            let usedVar = 42
            let unusedVar = 100

            func test() {
                print(usedVar)
            }
            """

        let config = UnusedCodeConfiguration(
            detectVariables: true,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // unusedVar should be detected
        let unusedVars = result.filter { $0.declaration.name == "unusedVar" }
        #expect(unusedVars.count >= 1)
    }

    @Test("Detect unused types")
    func detectUnusedTypes() async throws {
        let source = """
            struct UsedStruct {}
            struct UnusedStruct {}

            let instance = UsedStruct()
            """

        let config = UnusedCodeConfiguration(
            detectTypes: true,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // UnusedStruct should be detected
        let unusedTypes = result.filter { $0.declaration.name == "UnusedStruct" }
        #expect(unusedTypes.count >= 1)
    }

    // MARK: - Access Level Filtering

    @Test("Ignore public API when configured")
    func ignorePublicAPI() async throws {
        let source = """
            public func publicAPI() {
                print("public")
            }

            private func privateUnused() {
                print("private")
            }
            """

        let config = UnusedCodeConfiguration(
            ignorePublicAPI: true,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // Public function should NOT be reported
        let publicFuncs = result.filter { $0.declaration.name == "publicAPI" }
        #expect(publicFuncs.isEmpty)

        // Private function should be reported
        let privateFuncs = result.filter { $0.declaration.name == "privateUnused" }
        #expect(privateFuncs.count >= 1)
    }

    @Test("Include public API when not ignoring")
    func includePublicAPI() async throws {
        let source = """
            public func publicUnused() {
                print("public unused")
            }
            """

        let config = UnusedCodeConfiguration(
            ignorePublicAPI: false,
            minimumConfidence: .low,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // Public function should be reported when not ignoring
        let publicFuncs = result.filter { $0.declaration.name == "publicUnused" }
        #expect(publicFuncs.count >= 1)
    }

    // MARK: - Confidence Levels

    @Test("Assign correct confidence levels")
    func assignConfidenceLevels() async throws {
        let source = """
            private func privateFunc() {}
            internal func internalFunc() {}
            public func publicFunc() {}
            """

        let config = UnusedCodeConfiguration(
            ignorePublicAPI: false,
            minimumConfidence: .low,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        let privateResult = result.first { $0.declaration.name == "privateFunc" }
        let internalResult = result.first { $0.declaration.name == "internalFunc" }
        let publicResult = result.first { $0.declaration.name == "publicFunc" }

        // Private should have high confidence
        #expect(privateResult?.confidence == .high)

        // Internal should have medium confidence
        #expect(internalResult?.confidence == .medium)

        // Public should have low confidence
        #expect(publicResult?.confidence == .low)
    }

    @Test("Filter by minimum confidence")
    func filterByMinimumConfidence() async throws {
        let source = """
            private func privateFunc() {}
            public func publicFunc() {}
            """

        let config = UnusedCodeConfiguration(
            ignorePublicAPI: false,
            minimumConfidence: .high,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // Only high confidence (private) should be reported
        let privateResults = result.filter { $0.declaration.name == "privateFunc" }
        let publicResults = result.filter { $0.declaration.name == "publicFunc" }

        #expect(privateResults.count >= 1)
        #expect(publicResults.isEmpty)
    }

    // MARK: - Configuration Options

    @Test("Disable variable detection")
    func disableVariableDetection() async throws {
        let source = """
            let unusedVar = 42
            private func unusedFunc() {}
            """

        let config = UnusedCodeConfiguration(
            detectVariables: false,
            detectFunctions: true,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // Variables should not be reported
        let vars = result.filter { $0.declaration.kind == .variable || $0.declaration.kind == .constant }
        #expect(vars.isEmpty)

        // Functions should still be reported
        let funcs = result.filter { $0.declaration.kind == .function }
        #expect(funcs.count >= 1)
    }

    @Test("Disable function detection")
    func disableFunctionDetection() async throws {
        let source = """
            let unusedVar = 42
            private func unusedFunc() {}
            """

        let config = UnusedCodeConfiguration(
            detectVariables: true,
            detectFunctions: false,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // Functions should not be reported
        let funcs = result.filter { $0.declaration.kind == .function }
        #expect(funcs.isEmpty)
    }

    // MARK: - Unused Reasons

    @Test("Identify never referenced reason")
    func identifyNeverReferenced() async throws {
        let source = """
            private func neverCalled() {
                print("never")
            }
            """

        let detector = UnusedCodeDetector(configuration: .default)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        let unused = result.first { $0.declaration.name == "neverCalled" }
        #expect(unused?.reason == .neverReferenced)
    }

    // MARK: - Edge Cases

    @Test("Handle empty source")
    func handleEmptySource() async throws {
        let source = ""

        let detector = UnusedCodeDetector(configuration: .default)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        #expect(result.isEmpty)
    }

    @Test("Handle source with only comments")
    func handleOnlyComments() async throws {
        let source = """
            // This is a comment
            /* Block comment */
            """

        let detector = UnusedCodeDetector(configuration: .default)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        #expect(result.isEmpty)
    }

    @Test("Handle syntax errors gracefully")
    func handleSyntaxErrors() async throws {
        let source = """
            func broken( {
                let x =
            }
            """

        let detector = UnusedCodeDetector(configuration: .default)
        // Should not throw
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // May or may not find issues, but should not crash
        _ = result
    }
}

// MARK: - FalsePositivePreventionTests

@Suite("False Positive Prevention Tests")
struct FalsePositivePreventionTests {
    @Test("Private method called within same type is not unused")
    func privateMethodCalledWithinSameType() async throws {
        let source = """
            struct TokenNormalizer {
                func normalize(_ token: String) -> String {
                    return normalizeToken(token)
                }

                private func normalizeToken(_ token: String) -> String {
                    return token.uppercased()
                }
            }
            """

        let config = UnusedCodeConfiguration(
            detectFunctions: true,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // normalizeToken should NOT be detected as unused since it's called by normalize
        let unusedNormalizeToken = result.filter { $0.declaration.name == "normalizeToken" }
        #expect(unusedNormalizeToken.isEmpty, "normalizeToken is called and should not be marked as unused")
    }

    @Test("Variable used within closure is not unused")
    func variableUsedWithinClosure() async throws {
        let source = """
            func process() {
                let items = [1, 2, 3]
                let result = items.map { item in
                    let multiplier = 2
                    return item * multiplier
                }
                print(result)
            }
            """

        let config = UnusedCodeConfiguration(
            detectVariables: true,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // multiplier should NOT be detected as unused since it's used in the closure
        let unusedMultiplier = result.filter { $0.declaration.name == "multiplier" }
        #expect(unusedMultiplier.isEmpty, "multiplier is used and should not be marked as unused")
    }

    @Test("Variables declared and used in map closure are not unused")
    func variablesInMapClosure() async throws {
        let source = """
            func transform(_ groups: [Group]) -> [Result] {
                return groups.map { group in
                    let items = group.items.map { item -> Item in
                        let snippet: String
                        if item.hasValue {
                            snippet = item.value
                        } else {
                            snippet = ""
                        }
                        return Item(text: snippet)
                    }
                    return Result(items: items)
                }
            }
            """

        let config = UnusedCodeConfiguration(
            detectVariables: true,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // snippet and items should NOT be detected as unused
        let unusedSnippet = result.filter { $0.declaration.name == "snippet" }
        let unusedItems = result.filter { $0.declaration.name == "items" }
        #expect(unusedSnippet.isEmpty, "snippet is used and should not be marked as unused")
        #expect(unusedItems.isEmpty, "items is used and should not be marked as unused")
    }

    @Test("Struct with @main attribute is not unused")
    func structWithMainAttribute() async throws {
        let source = """
            import ArgumentParser

            @main
            struct CLI: AsyncParsableCommand {
                static let configuration = CommandConfiguration(
                    commandName: "cli",
                    abstract: "A CLI tool"
                )

                func run() async throws {
                    print("Running")
                }
            }
            """

        let config = UnusedCodeConfiguration(
            detectTypes: true,
            ignorePublicAPI: false,
            minimumConfidence: .low,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // CLI should NOT be detected as unused since it has @main
        let unusedCLI = result.filter { $0.declaration.name == "CLI" }
        #expect(unusedCLI.isEmpty, "CLI has @main attribute and should not be marked as unused")
    }

    @Test("Multiple helper functions called within type are not unused")
    func multipleHelperFunctions() async throws {
        let source = """
            class CloneDetector {
                func detect(_ input: [String]) -> [Clone] {
                    let validated = validate(input)
                    let normalized = normalize(validated)
                    return findClones(in: normalized)
                }

                private func validate(_ input: [String]) -> [String] {
                    return input.filter { !$0.isEmpty }
                }

                private func normalize(_ input: [String]) -> [String] {
                    return input.map { $0.lowercased() }
                }

                private func findClones(in input: [String]) -> [Clone] {
                    return []
                }
            }
            """

        let config = UnusedCodeConfiguration(
            detectFunctions: true,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // All private helper functions are called and should NOT be unused
        let unusedValidate = result.filter { $0.declaration.name == "validate" }
        let unusedNormalize = result.filter { $0.declaration.name == "normalize" }
        let unusedFindClones = result.filter { $0.declaration.name == "findClones" }

        #expect(unusedValidate.isEmpty, "validate is called and should not be marked as unused")
        #expect(unusedNormalize.isEmpty, "normalize is called and should not be marked as unused")
        #expect(unusedFindClones.isEmpty, "findClones is called and should not be marked as unused")
    }

    @Test("Filter clause variables are not unused")
    func filterClauseVariables() async throws {
        let source = """
            func filterData(_ items: [Item]) -> [Item] {
                let shouldExcludeEmpty = true
                let shouldExcludeHidden = true

                return items.filter { item in
                    if shouldExcludeEmpty && item.isEmpty {
                        return false
                    }
                    if shouldExcludeHidden && item.isHidden {
                        return false
                    }
                    return true
                }
            }
            """

        let config = UnusedCodeConfiguration(
            detectVariables: true,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: "test.swift")

        // shouldExcludeEmpty and shouldExcludeHidden are used in the filter closure
        let unusedExcludeEmpty = result.filter { $0.declaration.name == "shouldExcludeEmpty" }
        let unusedExcludeHidden = result.filter { $0.declaration.name == "shouldExcludeHidden" }

        #expect(unusedExcludeEmpty.isEmpty, "shouldExcludeEmpty is used and should not be marked as unused")
        #expect(unusedExcludeHidden.isEmpty, "shouldExcludeHidden is used and should not be marked as unused")
    }
}

// MARK: - UnusedCodeFixtureTests

@Suite("Unused Code Fixture Tests")
struct UnusedCodeFixtureTests {
    @Test("Detect unused code in IndirectReferences fixture")
    func detectInIndirectReferencesFixture() async throws {
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("UnusedCodeScenarios")
            .appendingPathComponent("IndirectReferences")
            .appendingPathComponent("HigherOrderFunctions.swift")

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            Issue.record("Fixture file not found")
            return
        }

        let source = try String(contentsOfFile: fixturesPath.path, encoding: .utf8)

        let config = UnusedCodeConfiguration(
            detectVariables: true,
            detectFunctions: true,
            ignorePublicAPI: false,
        )
        let detector = UnusedCodeDetector(configuration: config)
        let result = try await detector.detectFromSource(source, file: fixturesPath.path)

        // `bar` should be detected as unused
        let barUnused = result.contains { $0.declaration.name == "bar" }
        #expect(barUnused)

        // NOTE: Due to SwiftSyntax limitations, `foo` might still be flagged
        // as unused because indirect references are hard to detect without
        // semantic analysis. This is a known limitation of SwiftSyntax-only mode.
    }
}
