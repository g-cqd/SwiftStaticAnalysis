//  RegexCacheTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import SwiftStaticAnalysisCore

@Suite("Regex Cache Tests")
struct RegexCacheTests {
    @Test("Caches compiled regex and reports count")
    func cachesRegex() {
        let cache = RegexCache(capacity: 2)
        #expect(cache.count == 0)

        let regex = cache.regex(for: "foo.*bar")
        #expect(regex != nil)
        #expect(cache.isCached("foo.*bar") == true)
        #expect(cache.count == 1)

        if let regex {
            #expect("foo123bar".contains(regex) == true)
        }
    }

    @Test("Invalid pattern returns nil and is not cached")
    func invalidPatternNotCached() {
        let cache = RegexCache()
        let regex = cache.regex(for: "[invalid")

        #expect(regex == nil)
        #expect(cache.count == 0)
        #expect(cache.isCached("[invalid") == false)
    }

    @Test("Evicts when capacity is reached")
    func evictsWhenFull() {
        let cache = RegexCache(capacity: 1)
        #expect(cache.regex(for: "first") != nil)
        #expect(cache.isCached("first") == true)
        #expect(cache.count == 1)

        #expect(cache.regex(for: "second") != nil)
        #expect(cache.count == 1)
        #expect(cache.isCached("second") == true)
        #expect(cache.isCached("first") == false)
    }

    @Test("CompiledPatterns ignores invalid patterns")
    func compiledPatternsIgnoreInvalid() {
        let patterns = CompiledPatterns(["foo.*", "[invalid"])

        #expect(patterns.count == 1)
        #expect(patterns.isEmpty == false)
        #expect(patterns.anyMatches("foobar") == true)
        #expect(patterns.anyMatches("bar") == false)
    }
}
