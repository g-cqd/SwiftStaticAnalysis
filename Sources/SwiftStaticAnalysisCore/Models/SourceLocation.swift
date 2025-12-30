//
//  SourceLocation.swift
//  SwiftStaticAnalysis
//

import Foundation

// MARK: - SourceLocation

/// Represents a location within a source file.
public struct SourceLocation: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(file: String, line: Int, column: Int, offset: Int = 0) {
        self.file = file
        self.line = line
        self.column = column
        self.offset = offset
    }

    // MARK: Public

    /// The file path.
    public let file: String

    /// Line number (1-indexed).
    public let line: Int

    /// Column number (1-indexed).
    public let column: Int

    /// Byte offset from start of file.
    public let offset: Int
}

// MARK: - SourceRange

/// Represents a range of source code.
public struct SourceRange: Sendable, Hashable, Codable {
    // MARK: Lifecycle

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }

    // MARK: Public

    /// Start location.
    public let start: SourceLocation

    /// End location.
    public let end: SourceLocation

    /// Number of lines spanned by this range.
    public var lineCount: Int {
        end.line - start.line + 1
    }
}
