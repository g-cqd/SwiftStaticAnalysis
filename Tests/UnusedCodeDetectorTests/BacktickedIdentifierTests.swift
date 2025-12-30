//
//  BacktickedIdentifierTests.swift
//  SwiftStaticAnalysis
//
//  ## Test Goals
//  - Verify backticked identifier detection
//
//  ## Coverage
//  - Detects backticked identifiers
//  - Rejects non-backticked identifiers
//  - Rejects partial backticks
//

import Foundation
import Testing
@testable import UnusedCodeDetector

@Suite("Backticked Identifier Detection Tests")
struct BacktickedIdentifierTests {
    @Test("Detects backticked identifier")
    func detectsBackticked() {
        #expect(UnusedCodeFilter.isBacktickedIdentifier("`class`") == true)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("`protocol`") == true)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("`default`") == true)
    }

    @Test("Rejects non-backticked identifier")
    func rejectsNonBackticked() {
        #expect(UnusedCodeFilter.isBacktickedIdentifier("class") == false)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("MyClass") == false)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("") == false)
    }

    @Test("Rejects partial backticks")
    func rejectsPartialBackticks() {
        #expect(UnusedCodeFilter.isBacktickedIdentifier("`class") == false)
        #expect(UnusedCodeFilter.isBacktickedIdentifier("class`") == false)
    }
}
