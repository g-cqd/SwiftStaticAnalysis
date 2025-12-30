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

import Foundation
import SwiftStaticAnalysisCore
import UnusedCodeDetector

/// Resolves symbols using the IndexStoreDB compiler index.
///
/// Provides O(log n) lookup via B+tree index for USR-based queries
/// and pattern matching for name-based queries.
///
/// ## Thread Safety
///
/// This type is `Sendable` because it wraps `IndexStoreReader`, which
/// internally handles thread safety via its `@unchecked Sendable` conformance.
/// All public methods can be called from any thread.
///
/// - SeeAlso: ``SymbolResolver`` for the protocol this type conforms to.
/// - SeeAlso: ``SyntaxResolver`` for syntax-based resolution fallback.
public struct IndexStoreResolver: SymbolResolver, UsageResolver, ReferenceChecker {
  private let reader: IndexStoreReader

  /// Creates a new IndexStore resolver.
  ///
  /// - Parameter reader: The IndexStoreReader to use.
  public init(reader: IndexStoreReader) {
    self.reader = reader
  }

  /// Resolves a query pattern to matching symbols.
  ///
  /// - Parameter pattern: The query pattern to resolve.
  /// - Returns: Array of matching symbols.
  ///
  /// - Note: Selector patterns (`.selector`, `.qualifiedSelector`) are resolved
  ///   by name only. IndexStore doesn't expose full signature info, so precise
  ///   selector matching requires `SyntaxResolver`.
  ///
  /// - Complexity: O(log n) for USR queries, O(n) for name-based queries.
  public func resolve(_ pattern: SymbolQuery.Pattern) async throws -> [SymbolMatch] {
    resolveSync(pattern)
  }

  /// Synchronous resolution for internal use.
  ///
  /// - Parameter pattern: The query pattern to resolve.
  /// - Returns: Array of matching symbols.
  func resolveSync(_ pattern: SymbolQuery.Pattern) -> [SymbolMatch] {
    switch pattern {
    case .simpleName(let name):
      return resolveByName(name)
    case .qualifiedName(let components):
      return resolveQualifiedName(components)
    case .selector(let name, let labels):
      return resolveBySelector(name: name, labels: labels)
    case .qualifiedSelector(let types, let name, let labels):
      return resolveQualifiedSelector(types: types, name: name, labels: labels)
    case .usr(let usr):
      return resolveByUSR(usr)
    case .regex(let regex):
      return resolveByRegex(regex)
    }
  }

  /// Finds all occurrences (usages) of a symbol.
  ///
  /// - Parameter match: The symbol to find usages for.
  /// - Returns: Array of occurrence locations.
  ///
  /// - Complexity: O(k) where k is the number of occurrences.
  public func findUsages(of match: SymbolMatch) async throws -> [SymbolOccurrence] {
    findUsagesSync(of: match)
  }

  /// Synchronous usage finding for internal use.
  ///
  /// - Parameter match: The symbol to find usages for.
  /// - Returns: Array of occurrence locations.
  func findUsagesSync(of match: SymbolMatch) -> [SymbolOccurrence] {
    guard let usr = match.usr else {
      return []
    }

    let occurrences = reader.findOccurrences(ofUSR: usr)

    return occurrences.compactMap { occ -> SymbolOccurrence? in
      // Filter to references only (not definitions)
      guard occ.roles.contains(.reference) ||
            occ.roles.contains(.call) ||
            occ.roles.contains(.read) ||
            occ.roles.contains(.write) else {
        return nil
      }

      return SymbolOccurrence(
        file: occ.file,
        line: occ.line,
        column: occ.column,
        kind: convertRoleToOccurrenceKind(occ.roles)
      )
    }
  }

  /// Checks if a symbol has any references.
  ///
  /// - Parameter usr: The USR of the symbol.
  /// - Returns: `true` if the symbol is referenced.
  ///
  /// - Complexity: O(1) to O(log n) depending on index structure.
  public func hasReferences(usr: String) async -> Bool {
    hasReferencesSync(usr: usr)
  }

  /// Synchronous reference checking for internal use.
  ///
  /// - Parameter usr: The USR of the symbol.
  /// - Returns: `true` if the symbol is referenced.
  func hasReferencesSync(usr: String) -> Bool {
    reader.hasReferences(usr: usr)
  }
}

// MARK: - Private Resolution Methods

extension IndexStoreResolver {
  private func resolveByName(_ name: String) -> [SymbolMatch] {
    let occurrences = reader.findOccurrences(ofSymbolNamed: name)

    // Filter to definitions and deduplicate by location
    var seen = Set<String>()
    var matches: [SymbolMatch] = []

    for occ in occurrences {
      guard occ.roles.contains(.definition) || occ.roles.contains(.declaration) else {
        continue
      }

      let locationKey = "\(occ.file):\(occ.line):\(occ.column)"
      guard !seen.contains(locationKey) else {
        continue
      }
      seen.insert(locationKey)

      matches.append(convertToSymbolMatch(occ))
    }

    return matches
  }

  private func resolveQualifiedName(_ components: [String]) -> [SymbolMatch] {
    guard components.count >= 2,
          let memberName = components.last else {
      return components.first.map { resolveByName($0) } ?? []
    }

    // Strategy: Find the container type, then find the member
    let containerName = components.dropLast().joined(separator: ".")

    // First, find all symbols matching the member name
    let memberOccurrences = reader.findOccurrences(ofSymbolNamed: memberName)

    // Filter to those that are definitions and match the container
    var matches: [SymbolMatch] = []
    var seen = Set<String>()

    for occ in memberOccurrences {
      guard occ.roles.contains(.definition) || occ.roles.contains(.declaration) else {
        continue
      }

      let locationKey = "\(occ.file):\(occ.line):\(occ.column)"
      guard !seen.contains(locationKey) else {
        continue
      }
      seen.insert(locationKey)

      // Check if the USR contains the container name
      // This is a heuristic - USRs encode the scope chain
      let usr = occ.symbol.usr

      // Look for the container in the USR
      // USR format: s:<length><name>...
      if usrContainsContext(usr, context: containerName) ||
         usrContainsContext(usr, context: components.dropLast().last ?? "") {
        var match = convertToSymbolMatch(occ)
        // Set containing type
        match = SymbolMatch(
          usr: match.usr,
          name: match.name,
          kind: match.kind,
          accessLevel: match.accessLevel,
          file: match.file,
          line: match.line,
          column: match.column,
          isStatic: match.isStatic,
          containingType: containerName,
          moduleName: match.moduleName,
          typeSignature: match.typeSignature,
          signature: match.signature,
          genericParameters: match.genericParameters,
          source: match.source
        )
        matches.append(match)
      }
    }

    return matches
  }

  private func resolveByUSR(_ usr: String) -> [SymbolMatch] {
    let occurrences = reader.findOccurrences(ofUSR: usr)

    // Get the first definition occurrence
    for occ in occurrences {
      if occ.roles.contains(.definition) || occ.roles.contains(.declaration) {
        return [convertToSymbolMatch(occ)]
      }
    }

    // If no definition, return the first occurrence
    if let first = occurrences.first {
      return [convertToSymbolMatch(first)]
    }

    return []
  }

  private func resolveByRegex(_ pattern: String) -> [SymbolMatch] {
    guard let regex = try? Regex(pattern) else {
      return []
    }

    // Get all definitions and filter by regex
    let allDefs = reader.allDefinitions()

    var matches: [SymbolMatch] = []
    var seen = Set<String>()

    for occ in allDefs {
      guard occ.symbol.name.contains(regex) else {
        continue
      }

      let locationKey = "\(occ.file):\(occ.line):\(occ.column)"
      guard !seen.contains(locationKey) else {
        continue
      }
      seen.insert(locationKey)

      matches.append(convertToSymbolMatch(occ))
    }

    return matches
  }

  private func resolveBySelector(name: String, labels: [String?]) -> [SymbolMatch] {
    // IndexStore doesn't expose full signatures, so we resolve by name
    // and filter by selector labels encoded in USR if possible
    let candidates = resolveByName(name)

    // Try to filter by selector from USR
    return candidates.filter { match in
      matchesSelectorFromUSR(match.usr, labels: labels)
    }
  }

  private func resolveQualifiedSelector(
    types: [String],
    name: String,
    labels: [String?]
  ) -> [SymbolMatch] {
    // Build qualified name components and resolve
    var components = types
    components.append(name)
    let candidates = resolveQualifiedName(components)

    // Filter by selector from USR
    return candidates.filter { match in
      matchesSelectorFromUSR(match.usr, labels: labels)
    }
  }

  /// Attempts to match selector labels from USR.
  ///
  /// Swift USRs encode parameter labels in the mangled name.
  /// This is a best-effort heuristic.
  private func matchesSelectorFromUSR(_ usr: String?, labels: [String?]) -> Bool {
    guard let usr else {
      // No USR = can't verify, accept as potential match
      return true
    }

    // Empty labels = no parameters
    if labels.isEmpty {
      // Check if USR suggests no parameters (heuristic)
      // Functions with parameters typically have longer USRs
      return true
    }

    // Try to match labels in USR
    // Swift USR format includes parameter labels with length prefix
    for label in labels {
      if let label {
        // Labeled parameter: check if USR contains the length-prefixed label
        let encoded = "\(label.count)\(label)"
        if !usr.contains(encoded) {
          return false
        }
      }
      // Unlabeled (_:) parameters don't add identifiable info to USR
    }

    return true
  }
}

// MARK: - Conversion Helpers

extension IndexStoreResolver {
  private func convertToSymbolMatch(_ occurrence: IndexedOccurrence) -> SymbolMatch {
    let decoder = USRDecoder()
    let decoded = decoder.decode(occurrence.symbol.usr)

    return SymbolMatch(
      usr: occurrence.symbol.usr,
      name: occurrence.symbol.name,
      kind: occurrence.symbol.kind.toDeclarationKind(),
      accessLevel: .internal,  // IndexStore doesn't expose access level
      file: occurrence.file,
      line: occurrence.line,
      column: occurrence.column,
      isStatic: decoded?.isStatic ?? false,
      containingType: decoded?.contextName,
      moduleName: nil,
      typeSignature: nil,
      source: .indexStore
    )
  }

  private func convertRoleToOccurrenceKind(_ roles: IndexedSymbolRoles) -> SymbolOccurrence.Kind {
    if roles.contains(.call) {
      return .call
    }
    if roles.contains(.write) {
      return .write
    }
    if roles.contains(.read) {
      return .read
    }
    if roles.contains(.reference) {
      return .reference
    }
    return .reference
  }

  /// Checks if a USR contains a context name.
  private func usrContainsContext(_ usr: String, context: String) -> Bool {
    // USR encodes names with length prefix: <length><name>
    let lengthPrefix = "\(context.count)\(context)"
    return usr.contains(lengthPrefix)
  }
}

// MARK: - SymbolOccurrence

/// Represents an occurrence of a symbol in source code.
public struct SymbolOccurrence: Sendable, Hashable, Codable {
  /// File path of the occurrence.
  public let file: String

  /// Line number (1-indexed).
  public let line: Int

  /// Column number (1-indexed).
  public let column: Int

  /// Kind of occurrence.
  public let kind: Kind

  /// Kinds of symbol occurrences.
  public enum Kind: String, Sendable, Codable {
    case definition
    case declaration
    case reference
    case call
    case read
    case write
  }

  /// Creates a new symbol occurrence.
  public init(file: String, line: Int, column: Int, kind: Kind) {
    self.file = file
    self.line = line
    self.column = column
    self.kind = kind
  }

  /// Location string in "file:line:column" format.
  public var locationString: String {
    "\(file):\(line):\(column)"
  }
}
