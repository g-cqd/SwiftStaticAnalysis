//
//  TestSuiteNameTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify test suite name detection
//
//  ## Coverage
//  - Names ending with Tests
//  - Names ending with Test
//  - Non-test names rejection
//

import Foundation
import Testing

@testable import UnusedCodeDetector

@Suite("Test Suite Name Detection Tests")
struct TestSuiteNameTests {
    @Test("Detects test suite names ending with Tests")
    func detectsTestsEnding() {
        #expect(UnusedCodeFilter.isTestSuiteName("MyClassTests") == true)
        #expect(UnusedCodeFilter.isTestSuiteName("FilterTests") == true)
        #expect(UnusedCodeFilter.isTestSuiteName("IntegrationTests") == true)
    }

    @Test("Detects test suite names ending with Test")
    func detectsTestEnding() {
        #expect(UnusedCodeFilter.isTestSuiteName("MyClassTest") == true)
        #expect(UnusedCodeFilter.isTestSuiteName("UnitTest") == true)
    }

    @Test("Rejects non-test names")
    func rejectsNonTest() {
        #expect(UnusedCodeFilter.isTestSuiteName("MyClass") == false)
        #expect(UnusedCodeFilter.isTestSuiteName("Testing") == false)
        #expect(UnusedCodeFilter.isTestSuiteName("TestHelper") == false)
        #expect(UnusedCodeFilter.isTestSuiteName("") == false)
    }
}
