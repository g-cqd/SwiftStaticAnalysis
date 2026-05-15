//  GlobMatcherTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import SwiftStaticAnalysisCore

@Suite("Glob Matcher Tests", .tags(.unit))
struct GlobMatcherTests {
    // MARK: - Whole-match anchoring regression
    //
    // `GlobMatcher` uses anchored `wholeMatch` semantics. The cases below
    // pin that contract so a future regression to `String.contains` would
    // fail the test.

    @Test(
        "Bare segment names match only as whole tokens, never as substrings",
        arguments: [
            // Bare segment names match only the literal filename under
            // whole-match semantics, never an arbitrary path containing
            // the segment.
            ("Tests", "/Users/me/project/Sources/Tests/Foo.swift", false),
            ("Sources", "/Users/me/project/Sources/Foo.swift", false),
            // Whole-match exact equality still works.
            ("/Users/me/project/Sources/Foo.swift", "/Users/me/project/Sources/Foo.swift", true),
        ] as [(String, String, Bool)]
    )
    func bareSegmentDoesNotPartialMatch(pattern: String, path: String, expected: Bool) {
        #expect(GlobMatcher.matches(path: path, pattern: pattern) == expected)
    }

    @Test(
        "Double-star wildcards match across directory separators",
        arguments: [
            ("**/Tests/**", "/p/Tests/Foo.swift", true),
            ("**/Tests/**", "/p/a/b/Tests/x/y/Foo.swift", true),
            ("**/Tests/**", "/p/Sources/Foo.swift", false),
            ("**/*Tests.swift", "/p/FooTests.swift", true),
            ("**/*Tests.swift", "/p/a/b/c/BarTests.swift", true),
            ("**/*Tests.swift", "/p/Foo.swift", false),
            ("Sources/**/*.swift", "Sources/a/b/Foo.swift", true),
            ("Sources/**/*.swift", "Sources/Foo.swift", true),
            ("Sources/**/*.swift", "Tests/Foo.swift", false),
        ] as [(String, String, Bool)]
    )
    func doubleStarSemantics(pattern: String, path: String, expected: Bool) {
        #expect(GlobMatcher.matches(path: path, pattern: pattern) == expected)
    }

    @Test(
        "Single-star wildcard does not cross directory separators",
        arguments: [
            ("Sources/*.swift", "Sources/Foo.swift", true),
            ("Sources/*.swift", "Sources/a/Foo.swift", false),
            ("*Tests*", "FooTests.swift", true),
            ("*Tests*", "a/FooTests.swift", false),
        ] as [(String, String, Bool)]
    )
    func singleStarSemantics(pattern: String, path: String, expected: Bool) {
        #expect(GlobMatcher.matches(path: path, pattern: pattern) == expected)
    }

    @Test(
        "Question-mark matches a single non-slash character",
        arguments: [
            ("F?o.swift", "Foo.swift", true),
            ("F?o.swift", "Fo.swift", false),  // ? requires exactly one char
            ("F?o.swift", "F/o.swift", false),  // ? does not match /
        ] as [(String, String, Bool)]
    )
    func questionMarkSemantics(pattern: String, path: String, expected: Bool) {
        #expect(GlobMatcher.matches(path: path, pattern: pattern) == expected)
    }

    @Test("Regex metacharacters in the glob pattern are matched literally")
    func metacharactersAreLiteral() {
        // `+` is not a glob metacharacter — must match literally, not
        // as a regex quantifier.
        #expect(GlobMatcher.matches(path: "C++/Foo.swift", pattern: "C++/Foo.swift"))
        // Same for parens.
        #expect(GlobMatcher.matches(path: "a(b)c.swift", pattern: "a(b)c.swift"))
        // Square brackets must not form a character class.
        #expect(GlobMatcher.matches(path: "a[bc].swift", pattern: "a[bc].swift"))
    }

    @Test("Pattern rejected by SafeRegex returns false without trapping")
    func safeRegexRejectionFailsClosed() {
        // SafeRegex rejects pathological nested-quantifier patterns; the
        // glob matcher must surface that as a non-match (fail-closed),
        // never as a crash or backtracking storm.
        #expect(GlobMatcher.matches(path: "/a/b/c", pattern: "(a+)+") == false)
    }
}
