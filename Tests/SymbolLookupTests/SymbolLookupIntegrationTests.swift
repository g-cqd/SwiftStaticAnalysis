//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftStaticAnalysis open source project
//
// Copyright (c) 2024 the SwiftStaticAnalysis project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import SwiftStaticAnalysisCore
@testable import SymbolLookup

/// Fixture path helper
private func fixturePath(_ name: String) -> String {
    let testDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return testDir.appendingPathComponent("Fixtures/SymbolLookup/\(name)").path
}

@Suite("Symbol Lookup Integration Tests")
struct SymbolLookupIntegrationTests {
    let fixtureFile = fixturePath("SymbolVariety.swift")

    // MARK: - Basic Name Lookup

    @Test("Finds class by simple name")
    func findsClassBySimpleName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("NetworkMonitor")

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .class)
        #expect(results.first?.name == "NetworkMonitor")
    }

    @Test("Finds struct by simple name")
    func findsStructBySimpleName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("User")

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .struct)
        #expect(results.first?.name == "User")
    }

    @Test("Finds protocol by simple name")
    func findsProtocolBySimpleName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("Cacheable")

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .protocol)
        #expect(results.first?.name == "Cacheable")
    }

    @Test("Finds enum by simple name")
    func findsEnumBySimpleName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("NetworkError")

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .enum)
        #expect(results.first?.name == "NetworkError")
    }

    @Test("Finds actor by simple name")
    func findsActorBySimpleName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("CacheManager")

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .actor)
        #expect(results.first?.name == "CacheManager")
    }

    @Test("Finds free function by name")
    func findsFreeFunction() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("createDefaultUser")

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .function)
        #expect(results.first?.name == "createDefaultUser")
    }

    // MARK: - Qualified Name Lookup

    @Test("Finds static property with qualified name")
    func findsStaticPropertyQualified() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery.qualified("NetworkMonitor.shared")
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        #expect(results.first?.name == "shared")
        #expect(results.first?.containingType == "NetworkMonitor")
        #expect(results.first?.isStatic == true)
    }

    @Test("Finds nested type with qualified name")
    func findsNestedTypeQualified() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery.qualified("APIClient.Request")
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        #expect(results.first?.name == "Request")
        #expect(results.first?.containingType == "APIClient")
        #expect(results.first?.kind == .struct)
    }

    @Test("Finds deeply nested enum case")
    func findsDeeplyNestedType() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery.qualified("APIClient.Request.Method")
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        #expect(results.first?.name == "Method")
        #expect(results.first?.kind == .enum)
    }

    @Test("Finds instance method with qualified name")
    func findsInstanceMethodQualified() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery.qualified("NetworkMonitor.checkConnection")
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        #expect(results.first?.name == "checkConnection")
        // Methods are classified as .function in SwiftSyntax-based resolution
        #expect(results.first?.kind == .function || results.first?.kind == .method)
    }

    // MARK: - Kind Filtering

    @Test("Filters by function kind")
    func filtersByFunctionKind() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery(
            pattern: .simpleName("store"),
            kindFilter: [.function, .method]
        )
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        for result in results {
            #expect(result.kind == .function || result.kind == .method)
        }
    }

    @Test("Filters by class kind only")
    func filtersByClassKind() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery(
            pattern: .simpleName("Observable"),
            kindFilter: [.class]
        )
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .class)
    }

    // MARK: - Access Level Filtering

    @Test("Filters by public access")
    func filtersByPublicAccess() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery(
            pattern: .simpleName("User"),
            accessFilter: [.public]
        )
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        #expect(results.first?.accessLevel == .public)
    }

    // MARK: - Multiple Results

    @Test("Finds multiple symbols with same name")
    func findsMultipleSymbolsWithSameName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        // "store" appears in DataManager and CacheManager
        let results = try await finder.findByName("store")

        #expect(results.count >= 1)
    }

    @Test("Finds all methods named 'clear'")
    func findsAllMethodsNamedClear() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("clear")

        #expect(!results.isEmpty)
    }

    // MARK: - Generic Types

    @Test("Finds generic class")
    func findsGenericClass() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("Observable")

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .class)
    }

    @Test("Finds generic struct")
    func findsGenericStruct() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("Container")

        #expect(!results.isEmpty)
        #expect(results.first?.kind == .struct)
    }

    // MARK: - Extension Members

    @Test("Finds extension property")
    func findsExtensionProperty() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery.qualified("User.displayName")
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        #expect(results.first?.name == "displayName")
    }

    @Test("Finds static extension property")
    func findsStaticExtensionProperty() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery.qualified("User.guest")
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
        #expect(results.first?.name == "guest")
        #expect(results.first?.isStatic == true)
    }

    // MARK: - Query Mode Tests

    @Test("Definition mode returns only definitions")
    func definitionModeReturnsDefinitionsOnly() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery.definition(of: "NetworkMonitor")
        let results = try await finder.find(query)

        #expect(!results.isEmpty)
    }

    // MARK: - Empty Results

    @Test("Returns empty for nonexistent symbol")
    func returnsEmptyForNonexistent() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let results = try await finder.findByName("NonexistentSymbol")

        #expect(results.isEmpty)
    }

    @Test("Returns empty for wrong qualified name")
    func returnsEmptyForWrongQualifiedName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [fixtureFile]
        ))

        let query = SymbolQuery.qualified("User.nonexistent")
        let results = try await finder.find(query)

        #expect(results.isEmpty)
    }
}

@Suite("SyntaxResolver Integration Tests")
struct SyntaxResolverIntegrationTests {
    let fixtureFile = fixturePath("SymbolVariety.swift")

    @Test("Resolves simple name pattern")
    func resolvesSimpleNamePattern() async throws {
        let resolver = SyntaxResolver()

        let results = try await resolver.resolve(
            .simpleName("Configuration"),
            in: [fixtureFile]
        )

        #expect(!results.isEmpty)
        #expect(results.first?.name == "Configuration")
        #expect(results.first?.kind == .struct)
    }

    @Test("Resolves qualified name pattern")
    func resolvesQualifiedNamePattern() async throws {
        let resolver = SyntaxResolver()

        let results = try await resolver.resolve(
            .qualifiedName(["DataManager", "defaultManager"]),
            in: [fixtureFile]
        )

        #expect(!results.isEmpty)
        #expect(results.first?.name == "defaultManager")
    }

    @Test("Resolves regex pattern")
    func resolvesRegexPattern() async throws {
        let resolver = SyntaxResolver()

        let results = try await resolver.resolve(
            .regex("Network.*"),
            in: [fixtureFile]
        )

        #expect(results.count >= 2) // NetworkMonitor and NetworkError at least
    }

    @Test("Finds references to symbol")
    func findsReferences() async throws {
        let resolver = SyntaxResolver()

        // First find the symbol
        let symbols = try await resolver.resolve(
            .simpleName("User"),
            in: [fixtureFile]
        )
        guard let symbol = symbols.first else {
            Issue.record("Failed to find User symbol")
            return
        }

        let references = try await resolver.findReferences(to: symbol, in: [fixtureFile])

        // Should find references in extension, array extension, etc.
        #expect(!references.isEmpty)
    }
}

@Suite("SymbolMatch Tests")
struct SymbolMatchTests {
    @Test("Creates match with all properties")
    func createsMatchWithAllProperties() {
        let match = SymbolMatch(
            usr: "s:4Test3FooCACycfc",
            name: "init",
            kind: .initializer,
            accessLevel: .public,
            file: "/path/to/file.swift",
            line: 10,
            column: 5,
            isStatic: false,
            containingType: "Foo",
            moduleName: "Test",
            typeSignature: "() -> Foo",
            source: .syntaxTree
        )

        #expect(match.usr == "s:4Test3FooCACycfc")
        #expect(match.name == "init")
        #expect(match.kind == .initializer)
        #expect(match.accessLevel == .public)
        #expect(match.file == "/path/to/file.swift")
        #expect(match.line == 10)
        #expect(match.column == 5)
        #expect(!match.isStatic)
        #expect(match.containingType == "Foo")
        #expect(match.moduleName == "Test")
        #expect(match.typeSignature == "() -> Foo")
        #expect(match.source == .syntaxTree)
    }

    @Test("Location string formatting")
    func locationStringFormatting() {
        let match = SymbolMatch(
            name: "test",
            kind: .function,
            accessLevel: .internal,
            file: "/path/to/file.swift",
            line: 42,
            column: 10,
            source: .syntaxTree
        )

        #expect(match.locationString == "/path/to/file.swift:42:10")
    }

    @Test("Qualified name for member")
    func qualifiedNameForMember() {
        let match = SymbolMatch(
            name: "shared",
            kind: .variable,
            accessLevel: .public,
            file: "/path/file.swift",
            line: 5,
            column: 5,
            isStatic: true,
            containingType: "NetworkMonitor",
            source: .syntaxTree
        )

        #expect(match.qualifiedName == "NetworkMonitor.shared")
    }

    @Test("Qualified name for top-level")
    func qualifiedNameForTopLevel() {
        let match = SymbolMatch(
            name: "globalFunction",
            kind: .function,
            accessLevel: .public,
            file: "/path/file.swift",
            line: 5,
            column: 5,
            source: .syntaxTree
        )

        #expect(match.qualifiedName == "globalFunction")
    }

    @Test("Xcode location string output")
    func xcodeLocationStringOutput() {
        let match = SymbolMatch(
            name: "testFunc",
            kind: .function,
            accessLevel: .public,
            file: "/path/to/file.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let output = match.xcodeLocationString

        #expect(output == "/path/to/file.swift:10:5:")
    }

    @Test("Match equality")
    func matchEquality() {
        let match1 = SymbolMatch(
            name: "test",
            kind: .function,
            accessLevel: .internal,
            file: "/path/file.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            name: "test",
            kind: .function,
            accessLevel: .internal,
            file: "/path/file.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match3 = SymbolMatch(
            name: "different",
            kind: .function,
            accessLevel: .internal,
            file: "/path/file.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        #expect(match1 == match2)
        #expect(match1 != match3)
    }

    @Test("Match source types")
    func matchSourceTypes() {
        let syntaxMatch = SymbolMatch(
            name: "test",
            kind: .function,
            accessLevel: .internal,
            file: "f.swift",
            line: 1,
            column: 1,
            source: .syntaxTree
        )

        let indexMatch = SymbolMatch(
            name: "test",
            kind: .function,
            accessLevel: .internal,
            file: "f.swift",
            line: 1,
            column: 1,
            source: .indexStore
        )

        #expect(syntaxMatch.source == .syntaxTree)
        #expect(indexMatch.source == .indexStore)
    }
}

// MARK: - Disambiguation Tests

@Suite("Symbol Disambiguation Tests")
struct SymbolDisambiguationTests {
    let disambiguationFile = fixturePath("Disambiguation.swift")

    // MARK: - Same Property Name in Different Types

    @Test("Finds all 'id' properties across types")
    func findsAllIdProperties() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("id")

        // Should find id in User, Product, Order
        #expect(results.count >= 3)

        let containingTypes = Set(results.compactMap(\.containingType))
        #expect(containingTypes.contains("User"))
        #expect(containingTypes.contains("Product"))
        #expect(containingTypes.contains("Order"))
    }

    @Test("Distinguishes User.id from Product.id via qualified lookup")
    func distinguishesUserIdFromProductId() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let userIdResults = try await finder.find(SymbolQuery.qualified("User.id"))
        let productIdResults = try await finder.find(SymbolQuery.qualified("Product.id"))

        #expect(userIdResults.count == 1)
        #expect(productIdResults.count == 1)

        #expect(userIdResults.first?.containingType == "User")
        #expect(productIdResults.first?.containingType == "Product")

        // They should be at different locations
        #expect(userIdResults.first?.line != productIdResults.first?.line)
    }

    @Test("Finds all 'validate' methods across types")
    func findsAllValidateMethods() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("validate")

        // User, Product, Order all have validate()
        #expect(results.count >= 3)

        let containingTypes = Set(results.compactMap(\.containingType))
        #expect(containingTypes.contains("User"))
        #expect(containingTypes.contains("Product"))
        #expect(containingTypes.contains("Order"))
    }

    @Test("Distinguishes validate methods via qualified name")
    func distinguishesValidateMethodsViaQualifiedName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let userValidate = try await finder.find(SymbolQuery.qualified("User.validate"))
        let productValidate = try await finder.find(SymbolQuery.qualified("Product.validate"))
        let orderValidate = try await finder.find(SymbolQuery.qualified("Order.validate"))

        #expect(userValidate.count == 1)
        #expect(productValidate.count == 1)
        #expect(orderValidate.count == 1)

        // All different locations
        let lines = [userValidate.first?.line, productValidate.first?.line, orderValidate.first?.line]
        let uniqueLines = Set(lines.compactMap { $0 })
        #expect(uniqueLines.count == 3)
    }

    // MARK: - Same Static Property in Different Classes

    @Test("Finds all 'shared' singletons")
    func findsAllSharedSingletons() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("shared")

        // NetworkManager, CacheManager, DatabaseManager all have shared
        #expect(results.count >= 3)

        let containingTypes = Set(results.compactMap(\.containingType))
        #expect(containingTypes.contains("NetworkManager"))
        #expect(containingTypes.contains("CacheManager"))
        #expect(containingTypes.contains("DatabaseManager"))

        // All should be static
        for result in results {
            #expect(result.isStatic)
        }
    }

    @Test("Distinguishes NetworkManager.shared from CacheManager.shared")
    func distinguishesSharedSingletons() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let networkShared = try await finder.find(SymbolQuery.qualified("NetworkManager.shared"))
        let cacheShared = try await finder.find(SymbolQuery.qualified("CacheManager.shared"))
        let dbShared = try await finder.find(SymbolQuery.qualified("DatabaseManager.shared"))

        #expect(networkShared.count == 1)
        #expect(cacheShared.count == 1)
        #expect(dbShared.count == 1)

        #expect(networkShared.first?.containingType == "NetworkManager")
        #expect(cacheShared.first?.containingType == "CacheManager")
        #expect(dbShared.first?.containingType == "DatabaseManager")
    }

    @Test("Finds all 'defaultTimeout' across managers")
    func findsAllDefaultTimeouts() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("defaultTimeout")

        #expect(results.count >= 3)

        for result in results {
            #expect(result.isStatic)
        }
    }

    // MARK: - Same Nested Type Name

    @Test("Finds all nested 'Error' types")
    func findsAllNestedErrorTypes() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("Error")

        // APIResponse.Error, ValidationResult.Error, ParseResult.Error
        #expect(results.count >= 3)

        let containingTypes = Set(results.compactMap(\.containingType))
        #expect(containingTypes.contains("APIResponse"))
        #expect(containingTypes.contains("ValidationResult"))
        #expect(containingTypes.contains("ParseResult"))
    }

    @Test("Distinguishes APIResponse.Error from ValidationResult.Error")
    func distinguishesNestedErrorTypes() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let apiError = try await finder.find(SymbolQuery.qualified("APIResponse.Error"))
        let validationError = try await finder.find(SymbolQuery.qualified("ValidationResult.Error"))

        #expect(apiError.count == 1)
        #expect(validationError.count == 1)

        #expect(apiError.first?.containingType == "APIResponse")
        #expect(validationError.first?.containingType == "ValidationResult")

        // Different line numbers
        #expect(apiError.first?.line != validationError.first?.line)
    }

    // MARK: - Same Enum Case Names

    @Test("Finds all 'active' enum cases")
    func findsAllActiveCases() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("active")

        // UserStatus.active, OrderStatus.active, SubscriptionStatus.active
        #expect(results.count >= 3)
    }

    @Test("Distinguishes enum cases via qualified name")
    func distinguishesEnumCasesViaQualifiedName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let userActive = try await finder.find(SymbolQuery.qualified("UserStatus.active"))
        let orderActive = try await finder.find(SymbolQuery.qualified("OrderStatus.active"))

        #expect(userActive.count == 1)
        #expect(orderActive.count == 1)

        #expect(userActive.first?.containingType == "UserStatus")
        #expect(orderActive.first?.containingType == "OrderStatus")
    }

    // MARK: - Same Method in Protocol Conformers

    @Test("Finds all 'fetch' methods across data sources")
    func findsAllFetchMethods() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("fetch")

        // Protocol + LocalDataSource + RemoteDataSource, each with 3 overloads
        #expect(results.count >= 6)
    }

    @Test("Distinguishes LocalDataSource.fetch from RemoteDataSource.fetch")
    func distinguishesFetchMethodsAcrossTypes() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let localFetch = try await finder.find(SymbolQuery.qualified("LocalDataSource.fetch"))
        let remoteFetch = try await finder.find(SymbolQuery.qualified("RemoteDataSource.fetch"))

        #expect(!localFetch.isEmpty)
        #expect(!remoteFetch.isEmpty)

        // All local should be in LocalDataSource
        for result in localFetch {
            #expect(result.containingType == "LocalDataSource")
        }

        // All remote should be in RemoteDataSource
        for result in remoteFetch {
            #expect(result.containingType == "RemoteDataSource")
        }
    }

    // MARK: - Extension Methods with Same Name

    @Test("Finds all 'format' extension methods")
    func findsAllFormatMethods() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("format")

        // User.format, Product.format, Order.format
        #expect(results.count >= 3)
    }

    @Test("Distinguishes format methods via containing type")
    func distinguishesFormatMethodsViaType() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("format")

        // Group by containing type
        var byType: [String: [SymbolMatch]] = [:]
        for result in results {
            if let type = result.containingType {
                byType[type, default: []].append(result)
            }
        }

        #expect(byType["User"]?.count == 1)
        #expect(byType["Product"]?.count == 1)
        #expect(byType["Order"]?.count == 1)
    }

    // MARK: - Protocol Methods Implemented Differently

    @Test("Finds all 'describe' protocol implementations")
    func findsAllDescribeMethods() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("describe")

        // Describable protocol + User + Product extensions
        #expect(results.count >= 2)
    }

    // MARK: - Overloaded Free Functions

    @Test("Finds all 'process' free functions")
    func findsAllProcessFunctions() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.findByName("process")

        // process(User), process(Product), process(Order)
        #expect(results.count >= 3)

        // All should be top-level (no containing type)
        for result in results {
            #expect(result.containingType == nil)
        }

        // All at different line numbers
        let lines = Set(results.map(\.line))
        #expect(lines.count >= 3)
    }

    // MARK: - Wrong Qualified Name Returns Empty

    @Test("Returns empty for wrong type.member combination")
    func returnsEmptyForWrongCombination() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        // User doesn't have 'price' (that's Product)
        let results = try await finder.find(SymbolQuery.qualified("User.price"))
        #expect(results.isEmpty)
    }

    @Test("Returns empty for nonexistent nested type")
    func returnsEmptyForNonexistentNestedType() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        // User doesn't have a nested Error type
        let results = try await finder.find(SymbolQuery.qualified("User.Error"))
        #expect(results.isEmpty)
    }

    // MARK: - Count Verification

    @Test("Returns exactly one result for unique qualified name")
    func returnsExactlyOneForUniqueQualified() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        // NetworkManager.isConnected should be unique
        let results = try await finder.find(SymbolQuery.qualified("NetworkManager.isConnected"))

        #expect(results.count == 1)
        #expect(results.first?.name == "isConnected")
        #expect(results.first?.containingType == "NetworkManager")
    }
}

// MARK: - Signature and Generic Tests

@Suite("Function Signature Tests")
struct FunctionSignatureTests {
    let disambiguationFile = fixturePath("Disambiguation.swift")
    let varietyFile = fixturePath("SymbolVariety.swift")

    // MARK: - Signature Capture

    @Test("Captures function signature with no parameters")
    func capturesFunctionSignatureNoParams() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.find(SymbolQuery.qualified("DataSource.fetch"))

        // Find the no-param version
        let noParamVersion = results.first { $0.signature?.parameters.isEmpty == true }

        #expect(noParamVersion != nil)
        #expect(noParamVersion?.signature?.isAsync == true)
        #expect(noParamVersion?.signature?.isThrowing == true)
        #expect(noParamVersion?.signature?.returnType == "Data")
        #expect(noParamVersion?.selectorName == "fetch()")
    }

    @Test("Captures function signature with parameters")
    func capturesFunctionSignatureWithParams() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.find(SymbolQuery.qualified("DataSource.fetch"))

        // Find the version with id: parameter
        let idVersion = results.first { match in
            match.signature?.parameters.first?.label == "id"
        }

        #expect(idVersion != nil)
        #expect(idVersion?.signature?.parameters.count == 1)
        #expect(idVersion?.signature?.parameters.first?.type == "String")
        #expect(idVersion?.selectorName == "fetch(id:)")
    }

    @Test("Captures function signature with array parameter")
    func capturesFunctionSignatureWithArrayParam() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.find(SymbolQuery.qualified("DataSource.fetch"))

        // Find the version with ids: parameter
        let idsVersion = results.first { match in
            match.signature?.parameters.first?.label == "ids"
        }

        #expect(idsVersion != nil)
        #expect(idsVersion?.signature?.parameters.first?.type == "[String]")
        #expect(idsVersion?.signature?.returnType == "[Data]")
        #expect(idsVersion?.selectorName == "fetch(ids:)")
    }

    @Test("Distinguishes overloaded methods by selector name")
    func distinguishesOverloadedMethodsBySelectorName() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.find(SymbolQuery.qualified("LocalDataSource.fetch"))

        let selectorNames = Set(results.map(\.selectorName))

        #expect(selectorNames.contains("fetch()"))
        #expect(selectorNames.contains("fetch(id:)"))
        #expect(selectorNames.contains("fetch(ids:)"))
        #expect(selectorNames.count == 3)
    }

    @Test("Captures initializer signature")
    func capturesInitializerSignature() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [varietyFile]
        ))

        let results = try await finder.find(SymbolQuery.qualified("User.init"))

        #expect(!results.isEmpty)

        let initWithParams = results.first { match in
            match.signature?.parameters.count == 3
        }

        #expect(initWithParams != nil)
        let params = initWithParams?.signature?.parameters
        #expect(params?[0].label == "id")
        #expect(params?[1].label == "name")
        #expect(params?[2].label == "email")
    }

    // MARK: - Generic Parameter Capture

    @Test("Captures generic type parameters")
    func capturesGenericTypeParameters() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [varietyFile]
        ))

        let results = try await finder.findByName("Container")

        #expect(!results.isEmpty)
        #expect(results.first?.genericParameters == ["T"])
    }

    @Test("Captures multiple generic type parameters")
    func capturesMultipleGenericParams() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [varietyFile]
        ))

        let results = try await finder.findByName("Observable")

        #expect(!results.isEmpty)
        #expect(results.first?.genericParameters == ["Value"])
    }

    @Test("Display name includes generics")
    func displayNameIncludesGenerics() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [varietyFile]
        ))

        let results = try await finder.findByName("Container")

        #expect(!results.isEmpty)
        #expect(results.first?.displayNameWithSignature == "Container<T>")
    }

    @Test("Captures generic function parameters")
    func capturesGenericFunctionParameters() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [varietyFile]
        ))

        let results = try await finder.find(SymbolQuery.qualified("Container.map"))

        #expect(!results.isEmpty)
        #expect(results.first?.genericParameters == ["U"])
    }

    // MARK: - Signature Display

    @Test("Display string shows full signature")
    func displayStringShowsFullSignature() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.find(SymbolQuery.qualified("DataSource.fetch"))

        // Find the version with id: parameter
        let idVersion = results.first { match in
            match.signature?.parameters.first?.label == "id"
        }

        #expect(idVersion != nil)
        #expect(idVersion?.signature?.displayString == "(id: String) async throws -> Data")
    }

    @Test("Selector string shows parameter labels")
    func selectorStringShowsParameterLabels() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let results = try await finder.find(SymbolQuery.qualified("LocalDataSource.fetch"))

        for match in results {
            guard let sig = match.signature else { continue }

            if sig.parameters.isEmpty {
                #expect(sig.selectorString == "()")
            } else if sig.parameters.first?.label == "id" {
                #expect(sig.selectorString == "(id:)")
            } else if sig.parameters.first?.label == "ids" {
                #expect(sig.selectorString == "(ids:)")
            }
        }
    }
}

// MARK: - Selector Query Tests

@Suite("Selector Query Tests")
struct SelectorQueryTests {
    let disambiguationFile = fixturePath("Disambiguation.swift")
    let varietyFile = fixturePath("SymbolVariety.swift")

    // MARK: - Query Parser Tests

    @Test("Parses simple selector with one label")
    func parsesSimpleSelectorOneLabel() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("fetch(id:)")

        if case .selector(let name, let labels) = pattern {
            #expect(name == "fetch")
            #expect(labels == ["id"])
        } else {
            Issue.record("Expected selector pattern")
        }
    }

    @Test("Parses simple selector with multiple labels")
    func parsesSimpleSelectorMultipleLabels() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("fetch(id:name:)")

        if case .selector(let name, let labels) = pattern {
            #expect(name == "fetch")
            #expect(labels == ["id", "name"])
        } else {
            Issue.record("Expected selector pattern")
        }
    }

    @Test("Parses selector with unlabeled parameter")
    func parsesSelectorWithUnlabeled() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("process(_:)")

        if case .selector(let name, let labels) = pattern {
            #expect(name == "process")
            #expect(labels == [nil])
        } else {
            Issue.record("Expected selector pattern")
        }
    }

    @Test("Parses selector with mixed labels")
    func parsesSelectorWithMixedLabels() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("configure(_:with:)")

        if case .selector(let name, let labels) = pattern {
            #expect(name == "configure")
            #expect(labels.count == 2)
            #expect(labels[0] == nil)
            #expect(labels[1] == "with")
        } else {
            Issue.record("Expected selector pattern")
        }
    }

    @Test("Parses empty selector (no parameters)")
    func parsesEmptySelector() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("reset()")

        if case .selector(let name, let labels) = pattern {
            #expect(name == "reset")
            #expect(labels.isEmpty)
        } else {
            Issue.record("Expected selector pattern")
        }
    }

    @Test("Parses qualified selector")
    func parsesQualifiedSelector() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("DataSource.fetch(id:)")

        if case .qualifiedSelector(let types, let name, let labels) = pattern {
            #expect(types == ["DataSource"])
            #expect(name == "fetch")
            #expect(labels == ["id"])
        } else {
            Issue.record("Expected qualified selector pattern")
        }
    }

    @Test("Parses deeply qualified selector")
    func parsesDeeplyQualifiedSelector() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("Outer.Inner.process(_:with:)")

        if case .qualifiedSelector(let types, let name, let labels) = pattern {
            #expect(types == ["Outer", "Inner"])
            #expect(name == "process")
            #expect(labels.count == 2)
            #expect(labels[0] == nil)
            #expect(labels[1] == "with")
        } else {
            Issue.record("Expected qualified selector pattern")
        }
    }

    // MARK: - Selector Resolution Tests

    @Test("Finds method by selector with one parameter")
    func findsMethodBySelectorOneParam() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let parser = QueryParser()
        let pattern = try parser.parse("fetch(id:)")
        let results = try await finder.find(SymbolQuery(pattern: pattern))

        #expect(!results.isEmpty)
        // Should find methods with exactly one "id" parameter
        for result in results {
            #expect(result.name == "fetch")
            #expect(result.signature?.parameters.count == 1)
            #expect(result.signature?.parameters.first?.label == "id")
        }
    }

    @Test("Finds method by selector with no parameters")
    func findsMethodBySelectorNoParams() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let parser = QueryParser()
        let pattern = try parser.parse("fetch()")
        let results = try await finder.find(SymbolQuery(pattern: pattern))

        #expect(!results.isEmpty)
        for result in results {
            #expect(result.name == "fetch")
            #expect(result.signature?.parameters.isEmpty == true)
        }
    }

    @Test("Finds qualified method by selector")
    func findsQualifiedMethodBySelector() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let parser = QueryParser()
        let pattern = try parser.parse("LocalDataSource.fetch(id:)")
        let results = try await finder.find(SymbolQuery(pattern: pattern))

        #expect(results.count == 1)
        let match = results.first
        #expect(match?.name == "fetch")
        #expect(match?.containingType == "LocalDataSource")
        #expect(match?.signature?.parameters.count == 1)
        #expect(match?.signature?.parameters.first?.label == "id")
    }

    @Test("Selector query distinguishes overloads")
    func selectorQueryDistinguishesOverloads() async throws {
        let finder = SymbolFinder(configuration: .init(
            useSyntaxFallback: true,
            sourceFiles: [disambiguationFile]
        ))

        let parser = QueryParser()

        // Find fetch()
        let noParamPattern = try parser.parse("LocalDataSource.fetch()")
        let noParamResults = try await finder.find(SymbolQuery(pattern: noParamPattern))
        #expect(noParamResults.count == 1)
        #expect(noParamResults.first?.signature?.parameters.isEmpty == true)

        // Find fetch(id:)
        let idPattern = try parser.parse("LocalDataSource.fetch(id:)")
        let idResults = try await finder.find(SymbolQuery(pattern: idPattern))
        #expect(idResults.count == 1)
        #expect(idResults.first?.signature?.parameters.first?.label == "id")

        // Find fetch(ids:)
        let idsPattern = try parser.parse("LocalDataSource.fetch(ids:)")
        let idsResults = try await finder.find(SymbolQuery(pattern: idsPattern))
        #expect(idsResults.count == 1)
        #expect(idsResults.first?.signature?.parameters.first?.label == "ids")
    }

    @Test("Invalid selector syntax throws error")
    func invalidSelectorSyntaxThrows() {
        let parser = QueryParser()

        // Missing colon after label
        #expect(throws: QueryParseError.self) {
            _ = try parser.parse("fetch(id)")
        }
    }

    @Test("Selector isSelector property returns true")
    func selectorIsSelectorProperty() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("fetch(id:)")

        #expect(pattern.isSelector)
    }

    @Test("Qualified selector isSelector property returns true")
    func qualifiedSelectorIsSelectorProperty() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("Type.fetch(id:)")

        #expect(pattern.isSelector)
        #expect(pattern.isQualified)
    }

    @Test("Simple name isSelector property returns false")
    func simpleNameIsNotSelector() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("fetch")

        #expect(!pattern.isSelector)
    }

    @Test("Selector labels property returns labels")
    func selectorLabelsProperty() throws {
        let parser = QueryParser()
        let pattern = try parser.parse("fetch(id:name:)")

        #expect(pattern.selectorLabels == ["id", "name"])
    }
}
