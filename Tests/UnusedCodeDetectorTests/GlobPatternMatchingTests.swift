//  GlobPatternMatchingTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import Testing

@testable import UnusedCodeDetector

@Suite("Glob Pattern Matching Tests")
struct GlobPatternMatchingTests {
    @Test("Matches single star wildcard")
    func matchesSingleStar() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "/src/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/test.swift", pattern: "/src/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/sub/file.swift", pattern: "/src/*.swift") == false)
    }

    @Test("Matches double star wildcard")
    func matchesDoubleStar() {
        // 0.2.1: `**` matches zero or more path segments, including the
        // empty segment, so `/src/**/*.swift` matches both
        // `/src/file.swift` and `/src/sub/file.swift`. Pre-0.2.1 the
        // partial-match implementation returned `false` for the
        // zero-segment case; the canonical `GlobMatcher` now anchors
        // matches and uses `(?:.*/)?` for `**/`, which is the
        // user-intuitive shape and matches the `CodebaseContext` impl.
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/deep/nested/file.swift", pattern: "/src/**/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/sub/file.swift", pattern: "/src/**/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "/src/**/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/other/file.swift", pattern: "/src/**/*.swift") == false)
        // Pattern without trailing /* matches files directly too
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "/src/**.swift") == true)
    }

    @Test("Matches Tests directory pattern")
    func matchesTestsPattern() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/project/Tests/MyTests.swift", pattern: "**/Tests/**") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/Tests/file.swift", pattern: "**/Tests/**") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/Tests/nested/file.swift", pattern: "**/Tests/**") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "**/Tests/**") == false)
    }

    @Test("Matches Fixtures directory pattern")
    func matchesFixturesPattern() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/project/Fixtures/test.swift", pattern: "**/Fixtures/**") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/Tests/Fixtures/sample.swift", pattern: "**/Fixtures/**") == true)
    }

    @Test("Matches file suffix pattern")
    func matchesFileSuffix() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/MyClassTests.swift", pattern: "**/*Tests.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/deep/HelperTests.swift", pattern: "**/*Tests.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/MyClass.swift", pattern: "**/*Tests.swift") == false)
    }

    @Test("Escapes dots in patterns")
    func escapesDotsInPatterns() {
        // 0.2.1: `*` is a single-segment wildcard that does not cross
        // `/`. `*.swift` therefore matches only path-leaf-only inputs;
        // a leading `/src/` requires the pattern to declare structure
        // (`**/*.swift` or `/src/*.swift`). Pre-0.2.1 partial-match
        // semantics happily found `file.swift` as a substring of
        // `/src/file.swift`; the audit flagged that as misleading.
        #expect(UnusedCodeFilter.matchesGlobPattern("file.swift", pattern: "*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "*.swift") == false)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "**/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("fileXswift", pattern: "*.swift") == false)
    }

    @Test("Handles question mark wildcard")
    func handlesQuestionMark() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file1.swift", pattern: "/src/file?.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/fileA.swift", pattern: "/src/file?.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file12.swift", pattern: "/src/file?.swift") == false)
    }
}
