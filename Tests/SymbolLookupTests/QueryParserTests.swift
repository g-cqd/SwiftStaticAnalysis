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

import Testing
@testable import SymbolLookup

@Suite("QueryParser Tests")
struct QueryParserTests {
  let parser = QueryParser()

  @Test("Parses simple name")
  func parsesSimpleName() throws {
    let pattern = try parser.parse("shared")

    guard case .simpleName(let name) = pattern else {
      Issue.record("Expected simple name pattern")
      return
    }

    #expect(name == "shared")
  }

  @Test("Parses qualified name")
  func parsesQualifiedName() throws {
    let pattern = try parser.parse("NetworkMonitor.shared")

    guard case .qualifiedName(let components) = pattern else {
      Issue.record("Expected qualified name pattern")
      return
    }

    #expect(components == ["NetworkMonitor", "shared"])
  }

  @Test("Parses deeply nested qualified name")
  func parsesDeeplyNestedQualifiedName() throws {
    let pattern = try parser.parse("Module.Outer.Inner.method")

    guard case .qualifiedName(let components) = pattern else {
      Issue.record("Expected qualified name pattern")
      return
    }

    #expect(components == ["Module", "Outer", "Inner", "method"])
  }

  @Test("Detects Swift USR")
  func detectsSwiftUSR() throws {
    let pattern = try parser.parse("s:14NetworkMonitor6sharedACvpZ")

    guard case .usr(let usr) = pattern else {
      Issue.record("Expected USR pattern")
      return
    }

    #expect(usr == "s:14NetworkMonitor6sharedACvpZ")
  }

  @Test("Detects Clang USR")
  func detectsClangUSR() throws {
    let pattern = try parser.parse("c:@F@main")

    guard case .usr(let usr) = pattern else {
      Issue.record("Expected USR pattern")
      return
    }

    #expect(usr == "c:@F@main")
  }

  @Test("Parses regex pattern")
  func parsesRegexPattern() throws {
    let pattern = try parser.parse("/Network.*/")

    guard case .regex(let regex) = pattern else {
      Issue.record("Expected regex pattern")
      return
    }

    #expect(regex == "Network.*")
  }

  @Test("Throws on empty query")
  func throwsOnEmptyQuery() {
    #expect(throws: QueryParseError.self) {
      try parser.parse("")
    }
  }

  @Test("Throws on whitespace-only query")
  func throwsOnWhitespaceQuery() {
    #expect(throws: QueryParseError.self) {
      try parser.parse("   ")
    }
  }

  @Test("Handles generics in qualified names")
  func handlesGenericsInQualifiedNames() {
    let components = parser.parseQualifiedName("Array<Int>.Element")

    #expect(components == ["Array<Int>", "Element"])
  }

  @Test("USR detection returns false for simple names")
  func usrDetectionFalseForSimpleNames() {
    #expect(!parser.isUSR("shared"))
    #expect(!parser.isUSR("NetworkMonitor"))
    #expect(!parser.isUSR("fetchData"))
  }

  @Test("USR detection returns true for valid USRs")
  func usrDetectionTrueForValidUSRs() {
    #expect(parser.isUSR("s:14NetworkMonitor6sharedACvpZ"))
    #expect(parser.isUSR("c:@F@main"))
    #expect(parser.isUSR("s:4main"))
  }
}
