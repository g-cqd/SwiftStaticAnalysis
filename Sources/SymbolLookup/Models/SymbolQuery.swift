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

import SwiftStaticAnalysisCore

/// Represents a symbol lookup query with filters and mode selection.
///
/// Supports multiple query patterns:
/// - Simple name: `"shared"`
/// - Qualified name: `"NetworkMonitor.shared"`
/// - USR: `"s:14NetworkMonitor6sharedACvpZ"`
/// - Regex: `"Network.*"`
public struct SymbolQuery: Sendable {
  /// The search pattern to match.
  public let pattern: Pattern

  /// Filter results by declaration kind.
  public let kindFilter: Set<DeclarationKind>?

  /// Filter results by access level.
  public let accessFilter: Set<AccessLevel>?

  /// Scope filter - search within a specific type.
  public let scopeFilter: String?

  /// Query result mode.
  public let mode: Mode

  /// Maximum number of results to return (0 = unlimited).
  public let limit: Int

  /// Creates a new symbol query.
  ///
  /// - Parameters:
  ///   - pattern: The search pattern.
  ///   - kindFilter: Optional filter by declaration kind.
  ///   - accessFilter: Optional filter by access level.
  ///   - scopeFilter: Optional filter by containing type name.
  ///   - mode: Query result mode.
  ///   - limit: Maximum results (0 = unlimited).
  public init(
    pattern: Pattern,
    kindFilter: Set<DeclarationKind>? = nil,
    accessFilter: Set<AccessLevel>? = nil,
    scopeFilter: String? = nil,
    mode: Mode = .all,
    limit: Int = 0
  ) {
    self.pattern = pattern
    self.kindFilter = kindFilter
    self.accessFilter = accessFilter
    self.scopeFilter = scopeFilter
    self.mode = mode
    self.limit = limit
  }
}

// MARK: - SymbolQuery.Pattern

extension SymbolQuery {
  /// Pattern types for symbol lookup.
  public enum Pattern: Sendable, Hashable {
    /// Simple unqualified name lookup.
    case simpleName(String)

    /// Qualified name with type path.
    case qualifiedName([String])

    /// Selector-style lookup for functions/methods: `fetch(id:)`.
    /// - Parameters:
    ///   - name: The base function name
    ///   - labels: Parameter labels (nil for unlabeled `_:`)
    case selector(name: String, labels: [String?])

    /// Qualified selector: `Type.fetch(id:)`.
    /// - Parameters:
    ///   - types: The type path (e.g., ["Outer", "Inner"])
    ///   - name: The base function name
    ///   - labels: Parameter labels (nil for unlabeled `_:`)
    case qualifiedSelector(types: [String], name: String, labels: [String?])

    /// Direct USR lookup.
    case usr(String)

    /// Regex pattern for fuzzy matching.
    case regex(String)

    /// The primary identifier for this pattern.
    public var primaryIdentifier: String {
      switch self {
      case .simpleName(let name):
        return name
      case .qualifiedName(let components):
        return components.last ?? ""
      case .selector(let name, _):
        return name
      case .qualifiedSelector(_, let name, _):
        return name
      case .usr(let usr):
        return usr
      case .regex(let pattern):
        return pattern
      }
    }

    /// Whether this is a USR-based query.
    public var isUSR: Bool {
      if case .usr = self { return true }
      return false
    }

    /// Whether this is a qualified name query.
    public var isQualified: Bool {
      switch self {
      case .qualifiedName(let components):
        return components.count > 1
      case .qualifiedSelector:
        return true
      default:
        return false
      }
    }

    /// Whether this is a selector-based query.
    public var isSelector: Bool {
      switch self {
      case .selector, .qualifiedSelector:
        return true
      default:
        return false
      }
    }

    /// The selector labels if this is a selector pattern.
    public var selectorLabels: [String?]? {
      switch self {
      case .selector(_, let labels):
        return labels
      case .qualifiedSelector(_, _, let labels):
        return labels
      default:
        return nil
      }
    }
  }
}

// MARK: - SymbolQuery.Mode

extension SymbolQuery {
  /// Query result mode determining what to return.
  public enum Mode: String, Sendable, CaseIterable, Codable {
    /// Return only symbol definitions.
    case definition

    /// Return only usages/references to symbols.
    case usages

    /// Return both definitions and usages.
    case all
  }
}

// MARK: - Convenience Initializers

extension SymbolQuery {
  /// Creates a simple name query.
  ///
  /// - Parameter name: The symbol name to search for.
  /// - Returns: A query for the given name.
  public static func name(_ name: String) -> SymbolQuery {
    SymbolQuery(pattern: .simpleName(name))
  }

  /// Creates a qualified name query.
  ///
  /// - Parameter qualifiedName: The dot-separated qualified name.
  /// - Returns: A query for the qualified name.
  public static func qualified(_ qualifiedName: String) -> SymbolQuery {
    let components = qualifiedName.split(separator: ".").map(String.init)
    if components.count == 1 {
      return SymbolQuery(pattern: .simpleName(components[0]))
    }
    return SymbolQuery(pattern: .qualifiedName(components))
  }

  /// Creates a USR-based query.
  ///
  /// - Parameter usr: The Unified Symbol Resolution string.
  /// - Returns: A query for the USR.
  public static func usr(_ usr: String) -> SymbolQuery {
    SymbolQuery(pattern: .usr(usr))
  }

  /// Creates a definition-only query.
  ///
  /// - Parameter name: The symbol name.
  /// - Returns: A query for definitions only.
  public static func definition(of name: String) -> SymbolQuery {
    SymbolQuery(pattern: .simpleName(name), mode: .definition)
  }

  /// Creates a usages-only query.
  ///
  /// - Parameter name: The symbol name.
  /// - Returns: A query for usages only.
  public static func usages(of name: String) -> SymbolQuery {
    SymbolQuery(pattern: .simpleName(name), mode: .usages)
  }
}

// MARK: - CustomStringConvertible

extension SymbolQuery: CustomStringConvertible {
  public var description: String {
    var parts: [String] = []

    switch pattern {
    case .simpleName(let name):
      parts.append("name: \(name)")
    case .qualifiedName(let components):
      parts.append("qualified: \(components.joined(separator: "."))")
    case .selector(let name, let labels):
      let labelStr = labels.map { $0 ?? "_" }.joined(separator: ":")
      parts.append("selector: \(name)(\(labelStr):)")
    case .qualifiedSelector(let types, let name, let labels):
      let labelStr = labels.map { $0 ?? "_" }.joined(separator: ":")
      parts.append("selector: \(types.joined(separator: ".")).\(name)(\(labelStr):)")
    case .usr(let usr):
      parts.append("usr: \(usr)")
    case .regex(let pattern):
      parts.append("regex: /\(pattern)/")
    }

    if let kinds = kindFilter {
      parts.append("kinds: \(kinds.map(\.rawValue).joined(separator: ","))")
    }

    if let access = accessFilter {
      parts.append("access: \(access.map(\.rawValue).joined(separator: ","))")
    }

    if let scope = scopeFilter {
      parts.append("in: \(scope)")
    }

    parts.append("mode: \(mode.rawValue)")

    return "SymbolQuery(\(parts.joined(separator: ", ")))"
  }
}
