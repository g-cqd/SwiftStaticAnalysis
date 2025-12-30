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
import SwiftStaticAnalysisCore
@testable import SymbolLookup

@Suite("SymbolFinder Tests")
struct SymbolFinderTests {
  @Test("Creates finder without IndexStore")
  func createsFinderWithoutIndexStore() {
    let finder = SymbolFinder()

    #expect(!finder.hasIndexStore)
  }

  @Test("Creates finder with configuration")
  func createsFinderWithConfiguration() {
    let config = SymbolFinder.Configuration(
      useSyntaxFallback: false,
      sourceFiles: ["/path/to/source.swift"],
      includeSystemSymbols: true
    )
    let finder = SymbolFinder(configuration: config)

    #expect(!finder.hasIndexStore)
  }

  @Test("Default configuration enables syntax fallback")
  func defaultConfigurationEnablesSyntaxFallback() {
    let config = SymbolFinder.Configuration.default

    #expect(config.useSyntaxFallback)
    #expect(config.sourceFiles.isEmpty)
    #expect(!config.includeSystemSymbols)
  }

  @Test("Returns empty results without index or files")
  func returnsEmptyResultsWithoutIndexOrFiles() async throws {
    let finder = SymbolFinder()
    let results = try await finder.findByName("test")

    #expect(results.isEmpty)
  }

  @Test("Query with limit")
  func queryWithLimit() {
    let query = SymbolQuery(pattern: .simpleName("test"), limit: 5)

    #expect(query.limit == 5)
  }

  @Test("Query with kind filter")
  func queryWithKindFilter() {
    let query = SymbolQuery(
      pattern: .simpleName("test"),
      kindFilter: [.function, .method]
    )

    #expect(query.kindFilter?.contains(.function) == true)
    #expect(query.kindFilter?.contains(.method) == true)
    #expect(query.kindFilter?.contains(.variable) != true)
  }

  @Test("Query with access filter")
  func queryWithAccessFilter() {
    let query = SymbolQuery(
      pattern: .simpleName("test"),
      accessFilter: [.public, .open]
    )

    #expect(query.accessFilter?.contains(.public) == true)
    #expect(query.accessFilter?.contains(.open) == true)
    #expect(query.accessFilter?.contains(.private) != true)
  }

  @Test("Query with scope filter")
  func queryWithScopeFilter() {
    let query = SymbolQuery(
      pattern: .simpleName("test"),
      scopeFilter: "NetworkMonitor"
    )

    #expect(query.scopeFilter == "NetworkMonitor")
  }

  @Test("Query modes")
  func queryModes() {
    let definition = SymbolQuery(pattern: .simpleName("test"), mode: .definition)
    let usages = SymbolQuery(pattern: .simpleName("test"), mode: .usages)
    let all = SymbolQuery(pattern: .simpleName("test"), mode: .all)

    #expect(definition.mode == .definition)
    #expect(usages.mode == .usages)
    #expect(all.mode == .all)
  }

  @Test("Convenience initializers")
  func convenienceInitializers() {
    let nameQuery = SymbolQuery.name("shared")
    let qualifiedQuery = SymbolQuery.qualified("NetworkMonitor.shared")
    let usrQuery = SymbolQuery.usr("s:14NetworkMonitor6sharedACvpZ")
    let definitionQuery = SymbolQuery.definition(of: "test")
    let usagesQuery = SymbolQuery.usages(of: "test")

    if case .simpleName(let name) = nameQuery.pattern {
      #expect(name == "shared")
    } else {
      Issue.record("Expected simple name pattern")
    }

    if case .qualifiedName(let components) = qualifiedQuery.pattern {
      #expect(components == ["NetworkMonitor", "shared"])
    } else {
      Issue.record("Expected qualified name pattern")
    }

    if case .usr(let usr) = usrQuery.pattern {
      #expect(usr == "s:14NetworkMonitor6sharedACvpZ")
    } else {
      Issue.record("Expected USR pattern")
    }

    #expect(definitionQuery.mode == .definition)
    #expect(usagesQuery.mode == .usages)
  }
}

@Suite("SymbolOccurrence Tests")
struct SymbolOccurrenceTests {
  @Test("Creates occurrence with location")
  func createsOccurrenceWithLocation() {
    let occurrence = SymbolOccurrence(
      file: "/path/to/file.swift",
      line: 42,
      column: 10,
      kind: .call
    )

    #expect(occurrence.file == "/path/to/file.swift")
    #expect(occurrence.line == 42)
    #expect(occurrence.column == 10)
    #expect(occurrence.kind == .call)
  }

  @Test("Location string format")
  func locationStringFormat() {
    let occurrence = SymbolOccurrence(
      file: "/path/to/file.swift",
      line: 42,
      column: 10,
      kind: .reference
    )

    #expect(occurrence.locationString == "/path/to/file.swift:42:10")
  }

  @Test("Occurrence kinds")
  func occurrenceKinds() {
    let definition = SymbolOccurrence(file: "f", line: 1, column: 1, kind: .definition)
    let declaration = SymbolOccurrence(file: "f", line: 1, column: 1, kind: .declaration)
    let reference = SymbolOccurrence(file: "f", line: 1, column: 1, kind: .reference)
    let call = SymbolOccurrence(file: "f", line: 1, column: 1, kind: .call)
    let read = SymbolOccurrence(file: "f", line: 1, column: 1, kind: .read)
    let write = SymbolOccurrence(file: "f", line: 1, column: 1, kind: .write)

    #expect(definition.kind == .definition)
    #expect(declaration.kind == .declaration)
    #expect(reference.kind == .reference)
    #expect(call.kind == .call)
    #expect(read.kind == .read)
    #expect(write.kind == .write)
  }

  @Test("Occurrence equality")
  func occurrenceEquality() {
    let occ1 = SymbolOccurrence(file: "/path/file.swift", line: 10, column: 5, kind: .call)
    let occ2 = SymbolOccurrence(file: "/path/file.swift", line: 10, column: 5, kind: .call)
    let occ3 = SymbolOccurrence(file: "/path/file.swift", line: 10, column: 5, kind: .reference)

    #expect(occ1 == occ2)
    #expect(occ1 != occ3)
  }

  @Test("Occurrence hashable")
  func occurrenceHashable() {
    let occ1 = SymbolOccurrence(file: "/path/file.swift", line: 10, column: 5, kind: .call)
    let occ2 = SymbolOccurrence(file: "/path/file.swift", line: 10, column: 5, kind: .call)

    var set = Set<SymbolOccurrence>()
    set.insert(occ1)
    set.insert(occ2)

    #expect(set.count == 1)
  }
}

@Suite("IndexStoreResolver Tests")
struct IndexStoreResolverTests {
  @Test("USR contains context check")
  func usrContainsContext() {
    // Test the USR context matching logic
    // USR encodes names as <length><name>
    let usr = "s:14NetworkMonitor6sharedACvpZ"

    // "NetworkMonitor" has 14 characters
    #expect(usr.contains("14NetworkMonitor"))
    // "shared" has 6 characters
    #expect(usr.contains("6shared"))
  }
}
