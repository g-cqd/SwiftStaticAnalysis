//
//  GlobPatternMatchingTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify glob pattern matching for path exclusions
//
//  ## Coverage
//  - Single star wildcard (*)
//  - Double star wildcard (**)
//  - Tests and Fixtures directory patterns
//  - File suffix patterns
//  - Escaped dots
//  - Question mark wildcard (?)
//

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
        // ** matches zero or more path segments
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/deep/nested/file.swift", pattern: "/src/**/*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/sub/file.swift", pattern: "/src/**/*.swift") == true)
        // Note: /src/**/*.swift requires at least one directory segment due to the / after **
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "/src/**/*.swift") == false)
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
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file.swift", pattern: "*.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/fileXswift", pattern: "*.swift") == false)
    }

    @Test("Handles question mark wildcard")
    func handlesQuestionMark() {
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file1.swift", pattern: "/src/file?.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/fileA.swift", pattern: "/src/file?.swift") == true)
        #expect(UnusedCodeFilter.matchesGlobPattern("/src/file12.swift", pattern: "/src/file?.swift") == false)
    }
}
