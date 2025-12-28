//
//  SourceLocation.swift
//  SwiftStaticAnalysis
//

import Foundation

// MARK: - Source Location

/// Represents a location within a source file.
public struct SourceLocation: Sendable, Hashable, Codable {
    /// The file path.
    public let file: String

    /// Line number (1-indexed).
    public let line: Int

    /// Column number (1-indexed).
    public let column: Int

    /// Byte offset from start of file.
    public let offset: Int

    public init(file: String, line: Int, column: Int, offset: Int = 0) {
        self.file = file
        self.line = line
        self.column = column
        self.offset = offset
    }
}

// MARK: - Source Range

/// Represents a range of source code.
public struct SourceRange: Sendable, Hashable, Codable {
    /// Start location.
    public let start: SourceLocation

    /// End location.
    public let end: SourceLocation

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }

    /// Number of lines spanned by this range.
    public var lineCount: Int {
        end.line - start.line + 1
    }
}

// MARK: - CustomStringConvertible

extension SourceLocation: CustomStringConvertible {
    public var description: String {
        "\(file):\(line):\(column)"
    }
}

extension SourceRange: CustomStringConvertible {
    public var description: String {
        if start.line == end.line {
            return "\(start.file):\(start.line):\(start.column)-\(end.column)"
        } else {
            return "\(start.file):\(start.line)-\(end.line)"
        }
    }
}
