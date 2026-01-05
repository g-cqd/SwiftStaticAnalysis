//  RegexPatternsTests.swift
//  SwiftStaticAnalysis
//  MIT License

import Testing

@testable import SwiftStaticAnalysisCore

@Suite("Regex Patterns Tests")
struct RegexPatternsTests {
    @Test("Swift USR type context regex captures kind marker")
    func swiftUSRTypeContextCapturesMarker() {
        let match = "s:14NetworkMonitorC".firstMatch(of: swiftUSRTypeContextRegex)
        #expect(match != nil)
        #expect(match?.output.1 == "C")
        #expect("c:@F@main".contains(swiftUSRTypeContextRegex) == false)
    }

    @Test("Test file path regex matches expected paths")
    func testFilePathMatchesExpectedPaths() {
        #expect("/project/Tests/MyTests.swift".contains(testFilePathRegex) == true)
        #expect("/project/SampleTests.swift".contains(testFilePathRegex) == true)
        #expect("/project/SampleTest.swift".contains(testFilePathRegex) == true)
        #expect("/project/Testing.swift".contains(testFilePathRegex) == false)
        #expect("/project/Sources/MyClass.swift".contains(testFilePathRegex) == false)
    }

    @Test("Fixture path regex matches expected paths")
    func fixturePathMatchesExpectedPaths() {
        #expect("/project/Fixtures/Data.swift".contains(fixturePathRegex) == true)
        #expect("/project/Sources/Data.swift".contains(fixturePathRegex) == false)
    }

    @Test("Glob regex equivalents match expected paths")
    func globRegexEquivalentsMatchPaths() {
        #expect("/project/Tests/Thing.swift".contains(testsGlobRegex) == true)
        #expect("/project/Sources/Thing.swift".contains(testsGlobRegex) == false)
        #expect("/project/ThingTests.swift".contains(testFileSuffixGlobRegex) == true)
        #expect("/project/ThingTest.swift".contains(testFileSuffixGlobRegex) == false)
        #expect("/project/Fixtures/Thing.swift".contains(fixturesGlobRegex) == true)
    }

    @Test("Backticked identifier regex matches backticked names")
    func backtickedIdentifierMatchesBacktickedNames() {
        #expect("`class`".contains(backtickedIdentifierRegex) == true)
        #expect("class".contains(backtickedIdentifierRegex) == false)
    }
}
