//  QueryParser.swift
//  SwiftStaticAnalysis
//  MIT License

/// Parses symbol query strings into structured query patterns.
///
/// Supports multiple query formats:
/// - Simple names: `"shared"`, `"fetchData"`
/// - Qualified names: `"NetworkMonitor.shared"`, `"Foo.Bar.baz"`
/// - Selectors: `"fetch(id:)"`, `"fetch(_:name:)"`
/// - Qualified selectors: `"Type.fetch(id:)"`, `"Foo.Bar.process(_:)"`
/// - USRs: `"s:14NetworkMonitor6sharedACvpZ"`
/// - Regex patterns: `"/Network.*/"`
public struct QueryParser: Sendable {
    /// Creates a new query parser.
    public init() {}

    /// Parses a query string into a query pattern.
    ///
    /// - Parameter input: The query string to parse.
    /// - Returns: The parsed query pattern.
    /// - Throws: `QueryParseError` if the input is invalid.
    public func parse(_ input: String) throws(QueryParseError) -> SymbolQuery.Pattern {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw .emptyQuery
        }

        // Check for USR pattern (starts with "s:" for Swift or "c:" for Clang)
        if isUSR(trimmed) {
            return .usr(trimmed)
        }

        // Check for regex pattern (wrapped in forward slashes)
        if trimmed.hasPrefix("/") && trimmed.hasSuffix("/") && trimmed.count > 2 {
            let pattern = String(trimmed.dropFirst().dropLast())
            guard isValidRegex(pattern) else {
                throw .invalidRegex(pattern)
            }
            return .regex(pattern)
        }

        // Check for selector pattern (contains parentheses with optional labels)
        if let selectorPattern = try parseSelector(trimmed) {
            return selectorPattern
        }

        // Parse as simple or qualified name
        let components = parseQualifiedName(trimmed)

        guard !components.isEmpty else {
            throw .invalidIdentifier(trimmed)
        }

        if components.count == 1 {
            return .simpleName(components[0])
        }

        return .qualifiedName(components)
    }

    /// Parses a qualified name into components.
    ///
    /// Handles:
    /// - Simple dot separation: `"Foo.bar"` -> `["Foo", "bar"]`
    /// - Nested types: `"Outer.Inner.method"` -> `["Outer", "Inner", "method"]`
    /// - Operators are not split: `"Foo.+"` -> `["Foo", "+"]`
    ///
    /// - Parameter input: The qualified name string.
    /// - Returns: Array of name components.
    public func parseQualifiedName(_ input: String) -> [String] {
        var components: [String] = []
        var current = ""
        var depth = 0  // Track generic brackets

        for char in input {
            switch char {
            case "<":
                depth += 1
                current.append(char)
            case ">":
                depth -= 1
                current.append(char)
            case "." where depth == 0:
                if !current.isEmpty {
                    components.append(current)
                    current = ""
                }
            default:
                current.append(char)
            }
        }

        if !current.isEmpty {
            components.append(current)
        }

        return components
    }

    /// Checks if a string is a valid USR.
    ///
    /// USRs start with a schema prefix:
    /// - `s:` for Swift symbols
    /// - `c:` for Clang (C/C++/ObjC) symbols
    ///
    /// - Parameter input: The string to check.
    /// - Returns: `true` if it appears to be a USR.
    public func isUSR(_ input: String) -> Bool {
        // Swift USR
        if input.hasPrefix("s:") && input.count > 2 {
            return true
        }
        // Clang USR
        if input.hasPrefix("c:") && input.count > 2 {
            return true
        }
        return false
    }

    /// Validates that a string is a valid regex pattern.
    private func isValidRegex(_ pattern: String) -> Bool {
        do {
            _ = try Regex(pattern)
            return true
        } catch {
            return false
        }
    }

    /// Parses a selector pattern like `fetch(id:)` or `Type.fetch(id:name:)`.
    ///
    /// - Parameter input: The input string.
    /// - Returns: A selector pattern if the input is a valid selector, nil otherwise.
    /// - Throws: `QueryParseError` if the selector syntax is invalid.
    private func parseSelector(_ input: String) throws(QueryParseError) -> SymbolQuery.Pattern? {
        // Must contain parentheses
        guard let parenStart = input.firstIndex(of: "("),
            input.hasSuffix(")")
        else {
            return nil
        }

        let beforeParen = String(input[..<parenStart])
        let parenContent = String(input[input.index(after: parenStart)..<input.index(before: input.endIndex)])

        // Parse the labels from the parentheses content
        let labels = try parseSelectorLabels(parenContent)

        // Parse the qualified name before the parentheses
        let components = parseQualifiedName(beforeParen)

        guard !components.isEmpty else {
            throw .invalidIdentifier(input)
        }

        if components.count == 1 {
            // Simple selector: fetch(id:)
            return .selector(name: components[0], labels: labels)
        } else {
            // Qualified selector: Type.fetch(id:)
            // Safety: components.count >= 2 in this branch, so last is guaranteed
            guard let name = components.last else {
                return .selector(name: components[0], labels: labels)
            }
            let types = Array(components.dropLast())
            return .qualifiedSelector(types: types, name: name, labels: labels)
        }
    }

    /// Parses selector labels from parentheses content.
    ///
    /// Examples:
    /// - `""` -> `[]` (no parameters)
    /// - `"id:"` -> `["id"]`
    /// - `"_:"` -> `[nil]`
    /// - `"id:name:"` -> `["id", "name"]`
    /// - `"_:name:"` -> `[nil, "name"]`
    ///
    /// - Parameter content: The content between parentheses.
    /// - Returns: Array of labels (nil for unlabeled parameters).
    /// - Throws: `QueryParseError` if the syntax is invalid.
    private func parseSelectorLabels(_ content: String) throws(QueryParseError) -> [String?] {
        let trimmed = content.trimmingCharacters(in: .whitespaces)

        // Empty parentheses = no parameters
        if trimmed.isEmpty {
            return []
        }

        // Must end with colon for valid selector syntax
        guard trimmed.hasSuffix(":") else {
            throw .invalidSelector(content)
        }

        // Split by colons, dropping the trailing empty string
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let labels = parts.dropLast()  // Remove trailing empty string from final ":"

        return labels.map { label -> String? in
            let labelStr = label.trimmingCharacters(in: .whitespaces)
            if labelStr == "_" || labelStr.isEmpty {
                return nil
            }
            return labelStr
        }
    }
}

// MARK: - QueryParseError

/// Errors that can occur during query parsing.
public enum QueryParseError: Error, Sendable, CustomStringConvertible {
    /// The query string was empty.
    case emptyQuery

    /// The identifier is invalid.
    case invalidIdentifier(String)

    /// The regex pattern is invalid.
    case invalidRegex(String)

    /// The USR format is invalid.
    case invalidUSR(String)

    /// The selector syntax is invalid.
    case invalidSelector(String)

    public var description: String {
        switch self {
        case .emptyQuery:
            return "Query string cannot be empty"
        case .invalidIdentifier(let id):
            return "Invalid identifier: '\(id)'"
        case .invalidRegex(let pattern):
            return "Invalid regex pattern: '\(pattern)'"
        case .invalidUSR(let usr):
            return "Invalid USR format: '\(usr)'"
        case .invalidSelector(let selector):
            return "Invalid selector syntax: '\(selector)' (expected format: 'name(label:)' or 'name()')"
        }
    }
}
