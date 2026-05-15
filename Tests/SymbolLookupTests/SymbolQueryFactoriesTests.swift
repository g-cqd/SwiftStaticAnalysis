//  SymbolQueryFactoriesTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import SymbolLookup

@Suite("SymbolQuery convenience factories")
struct SymbolQueryFactoriesTests {
    @Test
    func `qualifiedName produces a two-component qualifiedName pattern`() throws {
        let sut = SymbolQuery.qualifiedName("APIClient", "shared")
        let components = try #require(qualifiedNameComponents(of: sut.pattern))
        #expect(components == ["APIClient", "shared"])
    }

    @Test
    func `qualifiedName supports a dot-separated member for deeper nesting`() throws {
        let sut = SymbolQuery.qualifiedName("Outer", "Inner.method")
        let components = try #require(qualifiedNameComponents(of: sut.pattern))
        #expect(components == ["Outer", "Inner", "method"])
    }

    @Test
    func `selector flattens labels into the Optional<String> form`() throws {
        let sut = SymbolQuery.selector("fetch", labels: ["id", "completion"])
        let extracted = try #require(selectorComponents(of: sut.pattern))
        #expect(extracted.name == "fetch")
        #expect(extracted.labels == [Optional("id"), Optional("completion")])
    }

    @Test
    func `selector with empty labels produces a zero-arity pattern`() throws {
        let sut = SymbolQuery.selector("reload", labels: [])
        let extracted = try #require(selectorComponents(of: sut.pattern))
        #expect(extracted.name == "reload")
        #expect(extracted.labels.isEmpty)
    }

    // MARK: - Pattern extractors

    private func qualifiedNameComponents(of pattern: SymbolQuery.Pattern) -> [String]? {
        if case .qualifiedName(let components) = pattern {
            return components
        }
        return nil
    }

    private func selectorComponents(of pattern: SymbolQuery.Pattern) -> (name: String, labels: [String?])? {
        if case .selector(let name, let labels) = pattern {
            return (name, labels)
        }
        return nil
    }
}
