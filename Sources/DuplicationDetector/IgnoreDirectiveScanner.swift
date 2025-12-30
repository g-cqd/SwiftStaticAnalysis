//
//  IgnoreDirectiveScanner.swift
//  SwiftStaticAnalysis
//
//  Scans source files for ignore directives to exclude regions from duplication detection.
//

import Foundation

// MARK: - IgnoreRegion

/// A region of code marked to be ignored from duplication detection.
public struct IgnoreRegion: Sendable, Equatable {
    /// The source file path.
    public let file: String

    /// Starting line number (1-based, inclusive).
    public let startLine: Int

    /// Ending line number (1-based, inclusive).
    public let endLine: Int

    /// Check if a line range overlaps with this region.
    public func overlaps(startLine: Int, endLine: Int) -> Bool {
        !(endLine < self.startLine || startLine > self.endLine)
    }
}

// MARK: - IgnoreDirectiveScanner

/// Scans source files for `swa:ignore-duplicates` directives.
///
/// Supported formats:
/// - `// swa:ignore-duplicates` - Ignores the following declaration/block
/// - `// swa:ignore-duplicates:begin` ... `// swa:ignore-duplicates:end` - Range ignore
/// - `// swa:ignore` - Generic ignore (also excludes from duplicates)
///
/// Example:
/// ```swift
/// // swa:ignore-duplicates
/// func generatedCode() {
///     // This function won't be flagged as duplicated
/// }
///
/// // swa:ignore-duplicates:begin
/// // All code in this region is excluded
/// struct GeneratedStruct1 { }
/// struct GeneratedStruct2 { }
/// // swa:ignore-duplicates:end
/// ```
public struct IgnoreDirectiveScanner: Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// Scan a source file for ignore regions.
    ///
    /// - Parameters:
    ///   - source: The source code content.
    ///   - file: The file path for reporting.
    /// - Returns: Array of ignore regions found in the file.
    public func scan(source: String, file: String) -> [IgnoreRegion] {
        var regions: [IgnoreRegion] = []
        let lines = source.components(separatedBy: .newlines)

        var rangeStartLine: Int?

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check for range markers
            if containsDirective(trimmed, directive: "swa:ignore-duplicates:begin") ||
                containsDirective(trimmed, directive: "swa:ignore:begin") {
                rangeStartLine = lineNumber
                continue
            }

            if containsDirective(trimmed, directive: "swa:ignore-duplicates:end") ||
                containsDirective(trimmed, directive: "swa:ignore:end") {
                if let start = rangeStartLine {
                    regions.append(IgnoreRegion(file: file, startLine: start, endLine: lineNumber))
                    rangeStartLine = nil
                }
                continue
            }

            // Check for single-line ignore (applies to next non-comment line)
            if containsDirective(trimmed, directive: "swa:ignore-duplicates") ||
                containsDirective(trimmed, directive: "swa:ignore") {
                // Find the extent of the following declaration
                if let extent = findDeclarationExtent(lines: lines, startingAt: index + 1) {
                    regions.append(IgnoreRegion(file: file, startLine: lineNumber, endLine: extent))
                }
            }
        }

        // Handle unclosed range (extends to end of file)
        if let start = rangeStartLine {
            regions.append(IgnoreRegion(file: file, startLine: start, endLine: lines.count))
        }

        return regions
    }

    /// Scan multiple files for ignore regions.
    ///
    /// - Parameter files: Array of file paths to scan.
    /// - Returns: Dictionary mapping file paths to their ignore regions.
    public func scan(files: [String]) throws -> [String: [IgnoreRegion]] {
        var result: [String: [IgnoreRegion]] = [:]

        for file in files {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            let regions = scan(source: source, file: file)
            if !regions.isEmpty {
                result[file] = regions
            }
        }

        return result
    }

    // MARK: Private

    /// Check if a line contains a specific directive.
    private func containsDirective(_ line: String, directive: String) -> Bool {
        // Check in line comments
        if line.hasPrefix("//"), line.contains(directive) {
            return true
        }
        // Check in block comments
        if line.contains("/*"), line.contains(directive), line.contains("*/") {
            return true
        }
        return false
    }

    /// Find the extent of a declaration starting at the given line index.
    /// Returns the line number where the declaration ends.
    private func findDeclarationExtent(lines: [String], startingAt index: Int) -> Int? {
        guard index < lines.count else { return nil }

        // Skip empty lines and comments
        var currentIndex = index
        while currentIndex < lines.count {
            let trimmed = lines[currentIndex].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/*") {
                break
            }
            currentIndex += 1
        }

        guard currentIndex < lines.count else { return nil }

        // Track brace depth to find end of declaration
        var braceDepth = 0
        var foundOpenBrace = false
        let startLine = currentIndex + 1

        for i in currentIndex ..< lines.count {
            let line = lines[i]

            for char in line {
                if char == "{" {
                    braceDepth += 1
                    foundOpenBrace = true
                } else if char == "}" {
                    braceDepth -= 1
                    if foundOpenBrace, braceDepth == 0 {
                        return i + 1 // Return 1-based line number
                    }
                }
            }

            // For single-line declarations without braces
            if !foundOpenBrace, i > currentIndex {
                // If we see a new declaration keyword, the previous one ended
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if startsNewDeclaration(trimmed) {
                    return i // Previous line was the end
                }
            }
        }

        // If no closing brace found, return the line after the directive
        return foundOpenBrace ? lines.count : startLine
    }

    /// Check if a line starts a new declaration.
    private func startsNewDeclaration(_ line: String) -> Bool {
        let declarationKeywords = [
            "func ", "var ", "let ", "class ", "struct ", "enum ",
            "protocol ", "extension ", "typealias ", "import ",
            "public ", "private ", "internal ", "fileprivate ", "open ",
            "@",
        ]
        return declarationKeywords.contains { line.hasPrefix($0) }
    }
}

// MARK: - CloneGroup Filtering

public extension [CloneGroup] {
    /// Filter clone groups to exclude clones in ignored regions.
    ///
    /// - Parameter ignoreRegions: Dictionary mapping file paths to their ignore regions.
    /// - Returns: Filtered clone groups with ignored clones removed.
    func filteringIgnored(_ ignoreRegions: [String: [IgnoreRegion]]) -> [CloneGroup] {
        compactMap { group in
            let filteredClones = group.clones.filter { clone in
                guard let regions = ignoreRegions[clone.file] else {
                    return true // No ignore regions for this file
                }
                // Keep clone if it doesn't overlap with any ignore region
                return !regions.contains { $0.overlaps(startLine: clone.startLine, endLine: clone.endLine) }
            }

            // Only keep groups with at least 2 clones
            guard filteredClones.count >= 2 else { return nil }

            return CloneGroup(
                type: group.type,
                clones: filteredClones,
                similarity: group.similarity,
                fingerprint: group.fingerprint,
            )
        }
    }
}
