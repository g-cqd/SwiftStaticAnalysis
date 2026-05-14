//  RegexPatterns.swift
//  SwiftStaticAnalysis
//  MIT License

import Foundation
import RegexBuilder

// MARK: - USR Patterns

/// Matches Swift USR type context pattern.
///
/// Format: `s:<length><name><kind-marker>`
///
/// Examples:
/// - `s:14NetworkMonitorC` - Class with 14-char name "NetworkMonitor"
/// - `s:7MyModelV` - Struct with 7-char name "MyModel"
/// - `s:6StatusO` - Enum with 6-char name "Status"
/// - `s:10MyProtocolP` - Protocol with 10-char name "MyProtocol"
///
/// Captures the kind marker character (C/V/O/P).
public nonisolated(unsafe) let swiftUSRTypeContextRegex = Regex {
    "s:"
    OneOrMore(.digit)
    OneOrMore(.word)
    Capture {
        One(CharacterClass.anyOf("CVOP"))
    }
}

// MARK: - File Path Patterns

/// Matches test file paths.
///
/// Matches paths containing `/Tests/` directory or ending with `Tests.swift` or `Test.swift`.
public nonisolated(unsafe) let testFilePathRegex = Regex {
    ChoiceOf {
        "/Tests/"
        Regex {
            "Tests.swift"
            Anchor.endOfSubject
        }
        Regex {
            "Test.swift"
            Anchor.endOfSubject
        }
    }
}

/// Matches fixture directory paths.
///
/// Matches paths containing `/Fixtures/` directory.
public nonisolated(unsafe) let fixturePathRegex = Regex {
    "/Fixtures/"
}

// MARK: - Glob Pattern Equivalents

/// Pre-compiled regex equivalent of glob pattern `**/Tests/**`.
///
/// Matches any path containing the `/Tests/` directory.
public nonisolated(unsafe) let testsGlobRegex = Regex {
    ZeroOrMore(.any)
    "/Tests/"
    ZeroOrMore(.any)
}

/// Pre-compiled regex equivalent of glob pattern `**/*Tests.swift`.
///
/// Matches any path ending with a filename that ends in `Tests.swift`.
public nonisolated(unsafe) let testFileSuffixGlobRegex = Regex {
    ZeroOrMore(.any)
    OneOrMore {
        CharacterClass.anyOf("/").inverted
    }
    "Tests.swift"
    Anchor.endOfSubject
}

/// Pre-compiled regex equivalent of glob pattern `**/Fixtures/**`.
///
/// Matches any path containing the `/Fixtures/` directory.
public nonisolated(unsafe) let fixturesGlobRegex = Regex {
    ZeroOrMore(.any)
    "/Fixtures/"
    ZeroOrMore(.any)
}

// MARK: - Swift Identifier Patterns

/// Matches backticked identifiers.
///
/// Swift allows keywords to be used as identifiers when wrapped in backticks.
/// Example: `` `class` ``, `` `func` ``, `` `default` ``
public nonisolated(unsafe) let backtickedIdentifierRegex = Regex {
    "`"
    OneOrMore {
        CharacterClass.anyOf("`").inverted
    }
    "`"
}

// MARK: - Path Helpers

/// Returns `true` when the path contains a `Tests` directory.
public func pathMatchesTestsGlob(_ path: String) -> Bool {
    URL(fileURLWithPath: path).pathComponents.contains("Tests")
}

/// Returns `true` when the path ends with a `*Tests.swift` filename.
public func pathMatchesTestFileSuffixGlob(_ path: String) -> Bool {
    URL(fileURLWithPath: path).lastPathComponent.hasSuffix("Tests.swift")
}

/// Returns `true` when the path contains a `Fixtures` directory.
public func pathMatchesFixturesGlob(_ path: String) -> Bool {
    URL(fileURLWithPath: path).pathComponents.contains("Fixtures")
}

/// Returns `true` when the path looks like a test file.
public func matchesTestFilePath(_ path: String) -> Bool {
    let fileName = URL(fileURLWithPath: path).lastPathComponent
    return pathMatchesTestsGlob(path)
        || fileName.hasSuffix("Tests.swift")
        || fileName.hasSuffix("Test.swift")
}

/// Returns `true` when the identifier is wrapped in backticks.
public func isBacktickedIdentifier(_ identifier: String) -> Bool {
    guard identifier.count >= 2, identifier.first == "`", identifier.last == "`" else {
        return false
    }

    return identifier.dropFirst().dropLast().allSatisfy { $0 != "`" }
}

/// Returns the type-context marker for a Swift USR when present.
public func swiftUSRTypeContextMarker(in usr: String) -> Character? {
    guard usr.hasPrefix("s:") else {
        return nil
    }

    let content = usr.dropFirst(2)
    var index = content.startIndex
    var lengthDigits = ""

    guard index < content.endIndex, content[index].isNumber else {
        return nil
    }

    while index < content.endIndex, content[index].isNumber {
        lengthDigits.append(content[index])
        index = content.index(after: index)
    }

    guard let nameLength = Int(lengthDigits), nameLength > 0 else {
        return nil
    }

    guard let markerIndex = content.index(index, offsetBy: nameLength, limitedBy: content.endIndex),
        markerIndex < content.endIndex
    else {
        return nil
    }

    let marker = content[markerIndex]
    return ["C", "V", "O", "P"].contains(marker) ? marker : nil
}
