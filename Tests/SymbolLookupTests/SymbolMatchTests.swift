//  SymbolMatchTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import SwiftStaticAnalysisCore
import SymbolLookup
import Testing

@Suite("SymbolMatch Unit Tests")
struct SymbolMatchUnitTests {
    // MARK: - Equality Tests

    @Test("Identical symbols are equal")
    func identicalSymbolsEqual() {
        let match1 = SymbolMatch(
            usr: "s:4test4funcSiyF",
            name: "func",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            usr: "s:4test4funcSiyF",
            name: "func",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        #expect(match1 == match2)
    }

    @Test("Different names make symbols unequal")
    func differentNamesUnequal() {
        let match1 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            name: "bar",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        #expect(match1 != match2)
    }

    @Test("Different locations make symbols unequal")
    func differentLocationsUnequal() {
        let match1 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 20,
            column: 5,
            source: .syntaxTree
        )

        #expect(match1 != match2)
    }

    // MARK: - Hashing Tests

    @Test("Identical symbols hash to same value")
    func identicalSymbolsHashSame() {
        let match1 = SymbolMatch(
            usr: "s:4test4funcSiyF",
            name: "func",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            usr: "s:4test4funcSiyF",
            name: "func",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        #expect(match1.hashValue == match2.hashValue)
    }

    @Test("Symbols can be used as Set elements")
    func symbolsInSet() {
        let match1 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            name: "bar",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 20,
            column: 5,
            source: .syntaxTree
        )

        let match3 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        var set = Set<SymbolMatch>()
        set.insert(match1)
        set.insert(match2)
        set.insert(match3)  // duplicate of match1

        #expect(set.count == 2)
    }

    @Test("Symbols can be used as Dictionary keys")
    func symbolsAsDictionaryKeys() {
        let match1 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            name: "bar",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 20,
            column: 5,
            source: .syntaxTree
        )

        var dict: [SymbolMatch: String] = [:]
        dict[match1] = "first"
        dict[match2] = "second"

        #expect(dict[match1] == "first")
        #expect(dict[match2] == "second")
    }

    // MARK: - Sorting Tests

    @Test("Symbols sort by file first")
    func sortByFile() {
        let match1 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/b.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            name: "bar",
            kind: .function,
            accessLevel: .internal,
            file: "/a.swift",
            line: 20,
            column: 5,
            source: .syntaxTree
        )

        let sorted = [match1, match2].sorted()
        #expect(sorted[0].file == "/a.swift")
        #expect(sorted[1].file == "/b.swift")
    }

    @Test("Symbols sort by line within same file")
    func sortByLine() {
        let match1 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 20,
            column: 5,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            name: "bar",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let sorted = [match1, match2].sorted()
        #expect(sorted[0].line == 10)
        #expect(sorted[1].line == 20)
    }

    @Test("Symbols sort by column within same line")
    func sortByColumn() {
        let match1 = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 20,
            source: .syntaxTree
        )

        let match2 = SymbolMatch(
            name: "bar",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let sorted = [match1, match2].sorted()
        #expect(sorted[0].column == 5)
        #expect(sorted[1].column == 20)
    }

    // MARK: - Convenience Property Tests

    @Test("qualifiedName with containing type")
    func qualifiedNameWithContainer() {
        let match = SymbolMatch(
            name: "foo",
            kind: .method,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            containingType: "MyClass",
            source: .syntaxTree
        )

        #expect(match.qualifiedName == "MyClass.foo")
    }

    @Test("qualifiedName without containing type")
    func qualifiedNameWithoutContainer() {
        let match = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        #expect(match.qualifiedName == "foo")
    }

    @Test("locationString format")
    func locationStringFormat() {
        let match = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/path/to/test.swift",
            line: 42,
            column: 13,
            source: .syntaxTree
        )

        #expect(match.locationString == "/path/to/test.swift:42:13")
    }

    @Test("xcodeLocationString format")
    func xcodeLocationStringFormat() {
        let match = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/path/to/test.swift",
            line: 42,
            column: 13,
            source: .syntaxTree
        )

        #expect(match.xcodeLocationString == "/path/to/test.swift:42:13:")
    }

    @Test("isType property for type kinds")
    func isTypeProperty() {
        let classMatch = SymbolMatch(
            name: "MyClass",
            kind: .class,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            source: .syntaxTree
        )
        #expect(classMatch.isType == true)

        let structMatch = SymbolMatch(
            name: "MyStruct",
            kind: .struct,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            source: .syntaxTree
        )
        #expect(structMatch.isType == true)

        let enumMatch = SymbolMatch(
            name: "MyEnum",
            kind: .enum,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            source: .syntaxTree
        )
        #expect(enumMatch.isType == true)

        let protocolMatch = SymbolMatch(
            name: "MyProtocol",
            kind: .protocol,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            source: .syntaxTree
        )
        #expect(protocolMatch.isType == true)

        let functionMatch = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            source: .syntaxTree
        )
        #expect(functionMatch.isType == false)
    }

    @Test("isMember property")
    func isMemberProperty() {
        let memberMatch = SymbolMatch(
            name: "foo",
            kind: .method,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            containingType: "MyClass",
            source: .syntaxTree
        )
        #expect(memberMatch.isMember == true)

        let topLevelMatch = SymbolMatch(
            name: "bar",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            source: .syntaxTree
        )
        #expect(topLevelMatch.isMember == false)
    }

    @Test("isInstanceMember property")
    func isInstanceMemberProperty() {
        let instanceMember = SymbolMatch(
            name: "foo",
            kind: .method,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            isStatic: false,
            containingType: "MyClass",
            source: .syntaxTree
        )
        #expect(instanceMember.isInstanceMember == true)

        let staticMember = SymbolMatch(
            name: "bar",
            kind: .method,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            isStatic: true,
            containingType: "MyClass",
            source: .syntaxTree
        )
        #expect(staticMember.isInstanceMember == false)
    }

    // MARK: - withContainingType Tests

    @Test("withContainingType creates new instance")
    func withContainingTypeCreatesNewInstance() {
        let original = SymbolMatch(
            name: "foo",
            kind: .method,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let withType = original.withContainingType("MyClass")

        #expect(withType.containingType == "MyClass")
        #expect(original.containingType == nil)
        #expect(withType.name == original.name)
        #expect(withType.line == original.line)
    }

    @Test("withContainingType can clear type")
    func withContainingTypeClearType() {
        let original = SymbolMatch(
            name: "foo",
            kind: .method,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            containingType: "MyClass",
            source: .syntaxTree
        )

        let withoutType = original.withContainingType(nil)

        #expect(withoutType.containingType == nil)
        #expect(original.containingType == "MyClass")
    }

    // MARK: - Factory Method Tests

    @Test("from(declaration:) creates correct match")
    func fromDeclaration() {
        let location = SourceLocation(file: "/test.swift", line: 15, column: 10)
        let range = SourceRange(
            start: location,
            end: SourceLocation(file: "/test.swift", line: 17, column: 1)
        )
        let declaration = Declaration(
            name: "testFunc",
            kind: .function,
            accessLevel: .public,
            modifiers: [.static],
            location: location,
            range: range,
            scope: .global,
            genericParameters: ["T"],
            signature: FunctionSignature(
                parameters: [
                    .init(label: "id", name: "id", type: "Int")
                ],
                returnType: "String",
                isAsync: false,
                isThrowing: false
            )
        )

        let match = SymbolMatch.from(
            declaration: declaration,
            usr: "s:test",
            containingType: "MyClass",
            source: .syntaxTree
        )

        #expect(match.name == "testFunc")
        #expect(match.kind == DeclarationKind.function)
        #expect(match.accessLevel == AccessLevel.public)
        #expect(match.file == "/test.swift")
        #expect(match.line == 15)
        #expect(match.column == 10)
        #expect(match.isStatic == true)
        #expect(match.containingType == "MyClass")
        #expect(match.usr == "s:test")
        #expect(match.signature != nil)
        #expect(match.genericParameters == ["T"])
        #expect(match.source == SymbolMatch.Source.syntaxTree)
    }

    // MARK: - Selector Name Tests

    @Test("selectorName without signature")
    func selectorNameWithoutSignature() {
        let match = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            source: .syntaxTree
        )

        #expect(match.selectorName == "foo")
    }

    @Test("selectorName with signature")
    func selectorNameWithSignature() {
        let match = SymbolMatch(
            name: "fetch",
            kind: .method,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            signature: FunctionSignature(
                parameters: [
                    .init(label: "id", name: "id", type: "Int"),
                    .init(label: nil, name: "force", type: "Bool"),
                ],
                returnType: "Data",
                isAsync: true,
                isThrowing: false
            ),
            source: .syntaxTree
        )

        #expect(match.selectorName == "fetch(id:_:)")
    }

    // MARK: - Display Name Tests

    @Test("displayNameWithSignature with generics")
    func displayNameWithGenerics() {
        let match = SymbolMatch(
            name: "transform",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 1,
            column: 1,
            genericParameters: ["T", "U"],
            source: .syntaxTree
        )

        #expect(match.displayNameWithSignature == "transform<T, U>")
    }

    @Test("displayNameWithSignature with signature and generics")
    func displayNameWithSignatureAndGenerics() {
        let match = SymbolMatch(
            name: "map",
            kind: .method,
            accessLevel: .public,
            file: "/test.swift",
            line: 1,
            column: 1,
            signature: FunctionSignature(
                parameters: [
                    .init(label: nil, name: "transform", type: "(T) -> U")
                ],
                returnType: "[U]",
                isAsync: false,
                isThrowing: true
            ),
            genericParameters: ["T", "U"],
            source: .syntaxTree
        )

        #expect(match.displayNameWithSignature.contains("map<T, U>"))
        #expect(match.displayNameWithSignature.contains("(T) -> U"))
    }

    // MARK: - Description Tests

    @Test("description includes key information")
    func descriptionIncludesKeyInfo() {
        let match = SymbolMatch(
            name: "foo",
            kind: .function,
            accessLevel: .internal,
            file: "/test.swift",
            line: 10,
            column: 5,
            source: .syntaxTree
        )

        let desc = match.description
        #expect(desc.contains("foo"))
        #expect(desc.contains("function"))
        #expect(desc.contains("/test.swift:10:5"))
    }

    @Test("description includes container and static")
    func descriptionWithContainerAndStatic() {
        let match = SymbolMatch(
            name: "shared",
            kind: .variable,
            accessLevel: .public,
            file: "/test.swift",
            line: 5,
            column: 1,
            isStatic: true,
            containingType: "Singleton",
            source: .syntaxTree
        )

        let desc = match.description
        #expect(desc.contains("static"))
        #expect(desc.contains("Singleton.shared"))
    }

    // MARK: - Codable Tests

    @Test("Symbol can be encoded and decoded")
    func codableRoundtrip() throws {
        let original = SymbolMatch(
            usr: "s:test",
            name: "foo",
            kind: .function,
            accessLevel: .public,
            file: "/test.swift",
            line: 10,
            column: 5,
            isStatic: false,
            containingType: "MyClass",
            moduleName: "TestModule",
            typeSignature: "() -> Int",
            signature: FunctionSignature(
                parameters: [],
                returnType: "Int",
                isAsync: false,
                isThrowing: false
            ),
            genericParameters: ["T"],
            source: .syntaxTree
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SymbolMatch.self, from: data)

        #expect(decoded == original)
        #expect(decoded.usr == "s:test")
        #expect(decoded.name == "foo")
        #expect(decoded.containingType == "MyClass")
        #expect(decoded.source == .syntaxTree)
    }

    // MARK: - Source Enum Tests

    @Test("Source enum has correct raw values")
    func sourceEnumRawValues() {
        let indexStore = SymbolMatch.Source.indexStore
        let syntaxTree = SymbolMatch.Source.syntaxTree
        let cached = SymbolMatch.Source.cached

        #expect(indexStore.rawValue == "indexStore")
        #expect(syntaxTree.rawValue == "syntaxTree")
        #expect(cached.rawValue == "cached")
    }
}
